import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { retentionResultSchema } from "@/lib/operations-contract";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { finishOperationRun, startOperationRun } from "@/server/operations/run-ledger";
import { readEmptyRequest } from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

async function closeFailedRun(
  admin: NonNullable<ReturnType<typeof getSupabaseAdminClient>>,
  runId: string,
  errorCode: string,
) {
  try {
    await finishOperationRun(admin, "retention", runId, "failed", 0, errorCode);
  } catch {
    // The private health gate will surface a stale running operation. Never
    // expose provider/database exceptions or leave this handler unbounded.
  }
}

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot de retentiejob." }, { status: 401 });
  const empty = await readEmptyRequest(request); if (!empty.ok) return empty.response;
  const runId = randomUUID();
  let admin: ReturnType<typeof getSupabaseAdminClient> = null;
  let started = false;
  try {
    admin = getSupabaseAdminClient();
    if (!admin) return NextResponse.json({ error: "Retentiejob tijdelijk niet beschikbaar." }, { status: 503 });
    started = await startOperationRun(admin, "retention", runId);
    if (!started) {
      return NextResponse.json({ error: "Retentiejob kon niet worden gemonitord." }, { status: 503 });
    }
    const now = new Date().toISOString();
    const { data, error } = await admin.schema("app").rpc(
      "cleanup_expired_security_data_v3",
      { p_now: now },
    );
    if (error) {
      await closeFailedRun(admin, runId, "cleanup_failed");
      return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
    }
    const {
      data: campaignPreflights,
      error: campaignRetentionError,
    } = await admin.schema("app").rpc(
      "purge_mail_v2_campaign_preflights_v1",
      {
        p_now: now,
        p_retention_hours: 24,
        p_limit: 500,
      },
    );
    if (campaignRetentionError) {
      await closeFailedRun(admin, runId, "campaign_cleanup_failed");
      return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
    }
    const {
      data: otpDeliveryHistory,
      error: otpDeliveryRetentionError,
    } = await admin.schema("app").rpc(
      "purge_parent_otp_delivery_history_v1",
      {
        p_now: now,
        p_retention_days: 90,
        p_limit: 500,
      },
    );
    if (otpDeliveryRetentionError) {
      await closeFailedRun(admin, runId, "otp_delivery_cleanup_failed");
      return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
    }
    const {
      data: supplierPlanningHistory,
      error: supplierRetentionError,
    } = await admin.schema("app").rpc(
      "purge_supplier_planner_history_v1",
      {
        p_event_retention_days: 365,
        p_limit: 500,
        p_now: now,
        p_session_retention_days: 30,
      },
    );
    if (supplierRetentionError) {
      await closeFailedRun(admin, runId, "supplier_cleanup_failed");
      return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
    }
    const parsed = retentionResultSchema.safeParse({
      ...(data && typeof data === "object" ? data : {}),
      campaignPreflights,
      otpDeliveryHistory,
      supplierPlanningHistory,
    });
    if (!parsed.success) {
      await closeFailedRun(admin, runId, "cleanup_response_invalid");
      return NextResponse.json({ error: "Ongeldig retentieresultaat." }, { status: 502 });
    }
    const deletedCount = Object.values(parsed.data).reduce((total, count) => total + count, 0);
    if (!await finishOperationRun(admin, "retention", runId, "succeeded", deletedCount)) {
      return NextResponse.json({ error: "Retentieresultaat kon niet worden gemonitord." }, { status: 503 });
    }
    return NextResponse.json({ status: "completed", deleted: parsed.data }, { headers: { "Cache-Control": "no-store" } });
  } catch {
    if (admin && started) await closeFailedRun(admin, runId, "cleanup_failed");
    return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
  }
}
