import { NextResponse } from "next/server";
import { operationalHealthSchema } from "@/lib/operations-contract";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot operationele status." }, { status: 401 });
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ status: "degraded", error: "database_unavailable" }, { status: 503 });
  const { data, error } = await admin.schema("app").rpc("get_operational_health");
  if (error) return NextResponse.json({ status: "degraded", error: "health_query_failed" }, { status: 503 });
  const parsed = operationalHealthSchema.safeParse(data);
  if (!parsed.success) return NextResponse.json({ status: "degraded", error: "health_response_invalid" }, { status: 502 });
  const degraded = parsed.data.emailJobs.processingStale > 0 || parsed.data.emailJobs.failed > 0 || parsed.data.reconciliationIssues > 0 || parsed.data.recentWebhookFailures > 0;
  return NextResponse.json({ status: degraded ? "degraded" : "ok", ...parsed.data }, { headers: { "Cache-Control": "no-store" } });
}

