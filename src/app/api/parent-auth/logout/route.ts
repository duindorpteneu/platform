import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { hashParentSecret } from "@/server/auth/parent";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { guardBrowserMutation, readEmptyRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: false }); if (guarded) return guarded;
  const empty = await readEmptyRequest(request); if (!empty.ok) return empty.response;
  const cookieStore = await cookies();
  const token = cookieStore.get("duindorp_parent_session")?.value;
  const admin = getSupabaseAdminClient();
  if (token && admin) await admin.schema("app").rpc("revoke_parent_session", { p_token_hash: hashParentSecret(token) });
  cookieStore.set("duindorp_parent_session", "", { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: 0 });
  return new NextResponse(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}
