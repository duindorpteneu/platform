import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { generateParentSessionToken, hashParentSecret, openParentChallengeEmail, parentCodeInputSchema } from "@/server/auth/parent";
import { consumeRateLimit, requestRateKey, valueRateKey } from "@/server/auth/rate-limit";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonTiny }); if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = parentCodeInputSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Voer de zescijferige code in." }, { status: 400 });
  const cookieStore = await cookies();
  const email = openParentChallengeEmail(cookieStore.get("duindorp_parent_challenge")?.value ?? "");
  if (!email) return NextResponse.json({ error: "Vraag eerst een nieuwe verificatiecode aan." }, { status: 401 });
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Inloggen is tijdelijk niet beschikbaar." }, { status: 503 });

  const [ipAllowed, emailAllowed] = await Promise.all([
    consumeRateLimit(admin, { scope: "otp_verify", keyHash: requestRateKey(request, "otp-verify-ip"), limit: 30, windowSeconds: 3_600 }),
    consumeRateLimit(admin, { scope: "otp_verify", keyHash: valueRateKey("otp-verify-email", email), limit: 15, windowSeconds: 3_600 }),
  ]);
  if (!ipAllowed || !emailAllowed) return NextResponse.json({ error: "Te veel verificatiepogingen. Vraag later een nieuwe code aan." }, { status: 429 });
  const { data: result, error } = await admin.rpc("consume_parent_otp", { p_email: email, p_code_hash: hashParentSecret(parsed.data.code) });
  if (error || !result || result.status !== "verified") return NextResponse.json({ error: "De code is ongeldig of verlopen." }, { status: 401 });

  const sessionToken = generateParentSessionToken();
  const { error: sessionError } = await admin.rpc("create_parent_session", { p_parent_account_id: result.parentAccountId, p_token_hash: hashParentSecret(sessionToken), p_expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString() });
  if (sessionError) return NextResponse.json({ error: "De sessie kon niet worden aangemaakt." }, { status: 503 });
  const tokenHash = hashParentSecret(sessionToken);
  const { data: candidates } = await admin.rpc("get_parent_candidates", { p_token_hash: tokenHash });
  if (Array.isArray(candidates) && candidates.length === 1 && typeof candidates[0]?.member_id === "string") {
    await admin.rpc("link_parent_member", { p_token_hash: tokenHash, p_member_id: candidates[0].member_id });
  }
  cookieStore.set("duindorp_parent_session", sessionToken, { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: 30 * 24 * 60 * 60 });
  cookieStore.set("duindorp_parent_challenge", "", { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: 0 });
  return NextResponse.json({ status: "verified" }, { status: 200 });
}
