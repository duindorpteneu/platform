import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { retentionResultSchema } from "@/lib/operations-contract";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { finishOperationRun, startOperationRun } from "@/server/operations/run-ledger";
import { readEmptyRequest } from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot de retentiejob." }, { status: 401 });
  const empty = await readEmptyRequest(request); if (!empty.ok) return empty.response;
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Retentiejob tijdelijk niet beschikbaar." }, { status: 503 });
  const runId = randomUUID();
  if (!await startOperationRun(admin, "retention", runId)) {
    return NextResponse.json({ error: "Retentiejob kon niet worden gemonitord." }, { status: 503 });
  }
  const { data, error } = await admin.schema("app").rpc("cleanup_expired_security_data_v2", { p_now: new Date().toISOString() });
  if (error) {
    await finishOperationRun(admin, "retention", runId, "failed", 0, "cleanup_failed");
    return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
  }
  const parsed = retentionResultSchema.safeParse(data);
  if (!parsed.success) {
    await finishOperationRun(admin, "retention", runId, "failed", 0, "cleanup_response_invalid");
    return NextResponse.json({ error: "Ongeldig retentieresultaat." }, { status: 502 });
  }
  const deletedCount = Object.values(parsed.data).reduce((total, count) => total + count, 0);
  if (!await finishOperationRun(admin, "retention", runId, "succeeded", deletedCount)) {
    return NextResponse.json({ error: "Retentieresultaat kon niet worden gemonitord." }, { status: 503 });
  }
  return NextResponse.json({ status: "completed", deleted: parsed.data }, { headers: { "Cache-Control": "no-store" } });
}
