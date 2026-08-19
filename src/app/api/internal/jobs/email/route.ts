import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { z } from "zod";
import { emailJobClaimResponseSchema, type ClaimedEmailJob } from "@/lib/email-contract";
import { getServerEnv } from "@/lib/env";
import {
  projectFulfilmentMail,
  projectMailV2DomainEvents,
} from "@/server/email/mail-v2-projector";
import { runDueMailReminders } from "@/server/email/mail-v2-reminders";
import { selectedEmailSender, sendEmailJob } from "@/server/email/provider";
import { renderClaimedEmailJob } from "@/server/email/workspace";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { isOperationalFeatureEnabled, type FeatureFlagClient } from "@/server/operations/feature-flags";
import { finishOperationRun, startOperationRun } from "@/server/operations/run-ledger";
import { readEmptyRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const completionResponseSchema = z.object({
  jobId: z.string().uuid(),
  status: z.enum(["sent", "retry", "failed", "delivery_uncertain"]),
  attempts: z.number().int().min(1).max(5),
  availableAt: z.string().datetime({ offset: true }),
}).strict();
const workerPreflightResponseSchema = z.object({
  ready: z.boolean(),
  brandingMatchCount: z.number().int().nonnegative(),
  senderDriftCount: z.number().int().nonnegative(),
  brandingProjectionBlockers: z.number().int().nonnegative().default(0),
}).strict();

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot de worker." }, { status: 401 });
  const empty = await readEmptyRequest(request); if (!empty.ok) return empty.response;
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "E-mailworker tijdelijk niet beschikbaar." }, { status: 503 });
  const runId = randomUUID();
  if (!await startOperationRun(admin, "email_worker", runId)) {
    return NextResponse.json({ error: "E-mailworker kon niet worden gemonitord." }, { status: 503 });
  }
  let env: ReturnType<typeof getServerEnv>;
  try {
    env = getServerEnv();
  } catch {
    await finishOperationRun(
      admin,
      "email_worker",
      runId,
      "failed",
      0,
      "runtime_configuration_invalid",
    );
    return NextResponse.json(
      { error: "E-mailworkerconfiguratie is ongeldig." },
      { status: 503 },
    );
  }
  if (env.EMAIL_ENABLED !== "true" || !await isOperationalFeatureEnabled(admin as unknown as FeatureFlagClient, "email_enabled")) {
    if (!await finishOperationRun(admin, "email_worker", runId, "paused", 0)) {
      return NextResponse.json({ error: "Gepauzeerde workerstatus kon niet worden vastgelegd." }, { status: 503 });
    }
    return NextResponse.json({ status: "paused", claimed: 0, sent: 0, retry: 0, failed: 0, deliveryUncertain: 0 });
  }
  const preflightResult = await admin.schema("app").rpc(
    "get_email_worker_preflight_v2",
    {
      p_from_name: env.SENDGRID_FROM_NAME,
      p_from_email: env.SENDGRID_FROM_EMAIL,
      p_reply_to_email: env.SENDGRID_REPLY_TO_EMAIL,
    },
  );
  const preflight = workerPreflightResponseSchema.safeParse(
    preflightResult.data,
  );
  if (preflightResult.error || !preflight.success || !preflight.data.ready) {
    await finishOperationRun(
      admin,
      "email_worker",
      runId,
      "failed",
      0,
      "sender_contract_drift",
    );
    return NextResponse.json(
      { error: "E-mailworkerpreflight blokkeert verzending." },
      { status: 503 },
    );
  }
  const appBaseUrl = env.APP_BASE_URL;
  let reminders;
  try {
    reminders = await runDueMailReminders(
      admin,
      new Date().toISOString(),
      500,
    );
  } catch {
    await finishOperationRun(
      admin,
      "email_worker",
      runId,
      "failed",
      0,
      "reminder_planner_failed",
    );
    return NextResponse.json(
      { error: "Herinneringsplanning kon niet veilig worden verwerkt." },
      { status: 503 },
    );
  }
  let projection;
  try {
    projection = {
      fulfilment: await projectFulfilmentMail(admin, appBaseUrl),
      domain: await projectMailV2DomainEvents(admin, appBaseUrl),
    };
  } catch {
    await finishOperationRun(
      admin,
      "email_worker",
      runId,
      "failed",
      0,
      "projection_failed",
    );
    return NextResponse.json(
      { error: "Mailprojectie kon niet veilig worden verwerkt." },
      { status: 503 },
    );
  }
  const claimToken = randomUUID();
  const { data, error } = await admin.schema("app").rpc("claim_email_jobs_v4", { p_claim_token: claimToken, p_limit: 25 });
  if (error) {
    await finishOperationRun(admin, "email_worker", runId, "failed", 0, "claim_failed");
    return NextResponse.json({ error: "E-mailjobs konden niet worden geclaimd." }, { status: 503 });
  }
  const claim = emailJobClaimResponseSchema.safeParse(data);
  if (!claim.success || claim.data.claimToken !== claimToken) {
    await finishOperationRun(admin, "email_worker", runId, "failed", 0, "claim_response_invalid");
    return NextResponse.json({ error: "Ongeldig claimantwoord van de database." }, { status: 502 });
  }

  const counts = {
    claimed: claim.data.jobs.length,
    sent: 0,
    retry: 0,
    failed: 0,
    deferred: 0,
    delivery_uncertain: 0,
    completionErrors: projection.fulfilment.errors + projection.domain.errors,
  };
  for (let offset = 0; offset < claim.data.jobs.length; offset += 5) {
    const settled = await Promise.allSettled(
      claim.data.jobs.slice(offset, offset + 5).map(
        (job) => processJob(job, claimToken, appBaseUrl, admin, counts),
      ),
    );
    counts.completionErrors += settled.filter(
      (item) => item.status === "rejected",
    ).length;
  }
  const operationStatus = counts.completionErrors > 0 ? "failed" : "succeeded";
  const operationRecorded = await finishOperationRun(
    admin,
    "email_worker",
    runId,
    operationStatus,
    counts.claimed,
    counts.completionErrors > 0 ? "completion_failed" : null,
  );
  if (!operationRecorded) return NextResponse.json({ error: "Workerresultaat kon niet worden gemonitord." }, { status: 503 });
  return NextResponse.json({
    status: counts.completionErrors > 0 ? "failed" : "processed",
    claimed: counts.claimed,
    sent: counts.sent,
    retry: counts.retry,
    failed: counts.failed,
    deferred: counts.deferred,
    deliveryUncertain: counts.delivery_uncertain,
    completionErrors: counts.completionErrors,
    projected: { reminders, ...projection },
  }, { status: counts.completionErrors > 0 ? 503 : 200 });
}

async function processJob(job: ClaimedEmailJob, claimToken: string, appBaseUrl: string, admin: NonNullable<ReturnType<typeof getSupabaseAdminClient>>, counts: { sent: number; retry: number; failed: number; deferred: number; delivery_uncertain: number; completionErrors: number }) {
  let outcome: "sent" | "retry" | "failed" | "delivery_uncertain" = "failed";
  let providerMessageId: string | null = null;
  let errorCode: string | null = "render_invalid";
  const authorization = await admin.schema("app").rpc(
    "authorize_claimed_email_job_v4",
    {
      p_job_id: job.id,
      p_claim_token: claimToken,
      p_delivery_attempt_id: job.deliveryAttemptId,
    },
  );
  if (authorization.error || typeof authorization.data !== "boolean") {
    throw new Error("EMAIL_JOB_AUTHORIZATION_FAILED");
  }
  if (!authorization.data) {
    counts.deferred += 1;
    return;
  }
  try {
    const rendered = job.contextKind === "fulfilment"
      || job.contextKind === "mail_v2"
      ? { subject: job.subject, text: job.text, html: job.html }
      : renderClaimedEmailJob(job, appBaseUrl);
    const sender = job.contextKind === "fulfilment"
      || job.contextKind === "mail_v2"
      ? {
        fromName: job.fromName,
        fromEmail: job.fromEmail,
        replyToEmail: job.replyToEmail,
      }
      : {
        ...selectedEmailSender(),
      };
    const delivery = await sendEmailJob({
      jobId: job.id,
      deliveryAttemptId: job.deliveryAttemptId,
      recipientEmail: job.recipientEmail,
      ...rendered,
      ...sender,
    });
    if (delivery.delivered) {
      outcome = "sent";
      providerMessageId = delivery.providerMessageId;
      errorCode = null;
    } else {
      outcome = delivery.outcome;
      errorCode = delivery.reason;
    }
  } catch {
    outcome = "failed";
    errorCode = "render_invalid";
  }
  const { data, error } = await admin.schema("app").rpc("complete_email_job_v2", {
    p_job_id: job.id,
    p_claim_token: claimToken,
    p_delivery_attempt_id: job.deliveryAttemptId,
    p_outcome: outcome,
    p_provider_message_id: providerMessageId,
    p_error: errorCode,
  });
  const completion = completionResponseSchema.safeParse(data);
  if (error || !completion.success || completion.data.jobId !== job.id) {
    throw new Error("EMAIL_JOB_COMPLETION_FAILED");
  }
  counts[completion.data.status] += 1;
}
