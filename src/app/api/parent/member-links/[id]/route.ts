import { NextResponse } from "next/server";
import { getParentSession } from "@/server/auth/parent-session";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { guardBrowserMutation, readEmptyRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const guarded = guardBrowserMutation(request, { body: false }); if (guarded) return guarded;
  const empty = await readEmptyRequest(request); if (!empty.ok) return empty.response;
  const session = await getParentSession(); const admin = getSupabaseAdminClient();
  if (!session || !admin) return NextResponse.json({ error: "Oudersessie vereist." }, { status: 401 });
  const { id } = await params;
  const { data, error } = await admin.rpc("unlink_parent_member", { p_token_hash: session.tokenHash, p_link_id: id });
  if (error) return NextResponse.json({ error: "De koppeling kon niet worden verwijderd." }, { status: 403 });
  return NextResponse.json({ unlinked: data === true });
}
