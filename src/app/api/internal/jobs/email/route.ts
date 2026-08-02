import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { z } from "zod";
import { emailJobClaimResponseSchema, type ClaimedEmailJob } from "@/lib/email-contract";
import { sendEmailJob } from "@/server/email/sendgrid";
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

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot de worker." }, { status: 401 });
  const empty = await readEmptyRequest(request); if (!empty.ok) return empty.response;
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "E-mailworker tijdelijk niet beschikbaar." }, { status: 503 });
  const runId = randomUUID();
  if (!await startOperationRun(admin, "email_worker", runId)) {
    return NextResponse.json({ error: "E-mailworker kon niet worden gemonitord." }, { status: 503 });
  }
  if (process.env.EMAIL_ENABLED !== "true" || !await isOperationalFeatureEnabled(admin as unknown as FeatureFlagClient, "email_enabled")) {
    if (!await finishOperationRun(admin, "email_worker", runId, "paused", 0)) {
      return NextResponse.json({ error: "Gepauzeerde workerstatus kon niet worden vastgelegd." }, { status: 503 });
    }
    return NextResponse.json({ status: "paused", claimed: 0, sent: 0, retry: 0, failed: 0, deliveryUncertain: 0 });
  }
  const claimToken = randomUUID();
  const { data, error } = await admin.schema("app").rpc("claim_email_jobs_v2", { p_claim_token: claimToken, p_limit: 25 });
  if (error) {
    await finishOperationRun(admin, "email_worker", runId, "failed", 0, "claim_failed");
    return NextResponse.json({ error: "E-mailjobs konden niet worden geclaimd." }, { status: 503 });
  }
  const claim = emailJobClaimResponseSchema.safeParse(data);
  if (!claim.success || claim.data.claimToken !== claimToken) {
    await finishOperationRun(admin, "email_worker", runId, "failed", 0, "claim_response_invalid");
    return NextResponse.json({ error: "Ongeldig claimantwoord van de database." }, { status: 502 });
  }

  const counts = { claimed: claim.data.jobs.length, sent: 0, retry: 0, failed: 0, delivery_uncertain: 0, completionErrors: 0 };
  const appBaseUrl = process.env.APP_BASE_URL ?? "http://localhost:3100";
  for (let offset = 0; offset < claim.data.jobs.length; offset += 5) {
    await Promise.allSettled(claim.data.jobs.slice(offset, offset + 5).map((job) => processJob(job, claimToken, appBaseUrl, admin, counts)));
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
    deliveryUncertain: counts.delivery_uncertain,
    completionErrors: counts.completionErrors,
  }, { status: counts.completionErrors > 0 ? 503 : 200 });
}

async function processJob(job: ClaimedEmailJob, claimToken: string, appBaseUrl: string, admin: NonNullable<ReturnType<typeof getSupabaseAdminClient>>, counts: { sent: number; retry: number; failed: number; delivery_uncertain: number; completionErrors: number }) {
  let outcome: "sent" | "retry" | "failed" | "delivery_uncertain" = "failed";
  let providerMessageId: string | null = null;
  let errorCode: string | null = "render_invalid";
  const authorization = await admin.schema("app").rpc(
    "authorize_claimed_email_job",
    {
      p_job_id: job.id,
      p_claim_token: claimToken,
    },
  );
  if (authorization.error || typeof authorization.data !== "boolean") {
    counts.completionErrors += 1;
    throw new Error("EMAIL_JOB_AUTHORIZATION_FAILED");
  }
  if (!authorization.data) {
    counts.failed += 1;
    return;
  }
  try {
    const rendered = renderClaimedEmailJob(job, appBaseUrl);
    const delivery = await sendEmailJob({ jobId: job.id, recipientEmail: job.recipientEmail, ...rendered, replyToEmail: job.payload.contactEmail ?? process.env.SENDGRID_REPLY_TO_EMAIL ?? "" });
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
  const { data, error } = await admin.schema("app").rpc("complete_email_job", {
    p_job_id: job.id,
    p_claim_token: claimToken,
    p_outcome: outcome,
    p_provider_message_id: providerMessageId,
    p_error: errorCode,
  });
  const completion = completionResponseSchema.safeParse(data);
  if (error || !completion.success || completion.data.jobId !== job.id) {
    counts.completionErrors += 1;
    throw new Error("EMAIL_JOB_COMPLETION_FAILED");
  }
  counts[completion.data.status] += 1;
}
