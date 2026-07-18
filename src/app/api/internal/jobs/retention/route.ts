import { NextResponse } from "next/server";
import { retentionResultSchema } from "@/lib/operations-contract";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot de retentiejob." }, { status: 401 });
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Retentiejob tijdelijk niet beschikbaar." }, { status: 503 });
  const { data, error } = await admin.schema("app").rpc("cleanup_expired_security_data", { p_now: new Date().toISOString() });
  if (error) return NextResponse.json({ error: "Retentiejob kon niet veilig worden uitgevoerd." }, { status: 503 });
  const parsed = retentionResultSchema.safeParse(data);
  if (!parsed.success) return NextResponse.json({ error: "Ongeldig retentieresultaat." }, { status: 502 });
  return NextResponse.json({ status: "completed", deleted: parsed.data }, { headers: { "Cache-Control": "no-store" } });
}

