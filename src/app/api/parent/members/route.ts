import { NextResponse } from "next/server";
import { getParentSession } from "@/server/auth/parent-session";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) return NextResponse.json({ error: "Oudersessie vereist." }, { status: 401 });
  const { data, error } = await admin.rpc("get_parent_members", { p_token_hash: session.tokenHash });
  if (error) return NextResponse.json({ error: "De leden konden niet worden geladen." }, { status: 503 });
  return NextResponse.json({ members: data ?? [] });
}
