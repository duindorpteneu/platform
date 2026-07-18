import { NextResponse } from "next/server";
import { getParentSession } from "@/server/auth/parent-session";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { parentMemberLinkSchema } from "@/server/auth/parent-links";
import { guardBrowserMutation } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request); if (guarded) return guarded;
  const session = await getParentSession(); const admin = getSupabaseAdminClient();
  if (!session || !admin) return NextResponse.json({ error: "Oudersessie vereist." }, { status: 401 });
  const parsed = parentMemberLinkSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Ongeldig lid." }, { status: 400 });
  const { data, error } = await admin.rpc("link_parent_member", { p_token_hash: session.tokenHash, p_member_id: parsed.data.memberId });
  if (error) return NextResponse.json({ error: "Dit lid kan niet aan dit account worden gekoppeld." }, { status: 403 });
  return NextResponse.json(data, { status: 201 });
}
