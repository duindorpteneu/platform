import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { generateParentSessionToken, hashParentSecret, normalizeParentEmail, parentCodeSchema } from "@/server/auth/parent";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const parsed = parentCodeSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Voer de zescijferige code in." }, { status: 400 });
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Inloggen is tijdelijk niet beschikbaar." }, { status: 503 });

  const email = normalizeParentEmail(parsed.data.email);
  const { data: result, error } = await admin.rpc("consume_parent_otp", { p_email: email, p_code_hash: hashParentSecret(parsed.data.code) });
  if (error || !result || result.status !== "verified") return NextResponse.json({ error: "De code is ongeldig of verlopen." }, { status: 401 });

  const sessionToken = generateParentSessionToken();
  const { error: sessionError } = await admin.rpc("create_parent_session", { p_parent_account_id: result.parentAccountId, p_token_hash: hashParentSecret(sessionToken), p_expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString() });
  if (sessionError) return NextResponse.json({ error: "De sessie kon niet worden aangemaakt." }, { status: 503 });
  const cookieStore = await cookies();
  cookieStore.set("duindorp_parent_session", sessionToken, { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: 30 * 24 * 60 * 60 });
  return NextResponse.json({ status: "verified" }, { status: 200 });
}
