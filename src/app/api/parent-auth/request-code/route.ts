import { NextResponse } from "next/server";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { generateParentCode, hashParentSecret, normalizeParentEmail, parentEmailSchema, sealParentChallengeEmail } from "@/server/auth/parent";
import { sendParentOtpEmail } from "@/server/email/sendgrid";
import { getParentOtpEmailTemplate, renderParentOtpEmail } from "@/server/email/otp";
import { consumeRateLimit, requestRateKey } from "@/server/auth/rate-limit";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { isOperationalFeatureEnabled, type FeatureFlagClient } from "@/server/operations/feature-flags";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const neutralResponse = { message: "Als dit e-mailadres bij ons bekend is, is een code verzonden." };

function neutralChallengeResponse(email: string) {
  const response = NextResponse.json(neutralResponse, { status: 202 });
  response.cookies.set("duindorp_parent_challenge", sealParentChallengeEmail(email), { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: 10 * 60 });
  return response;
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonTiny }); if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = parentEmailSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Voer een geldig e-mailadres in." }, { status: 400 });

  const email = normalizeParentEmail(parsed.data.email);
  const admin = getSupabaseAdminClient();
  if (!admin) return neutralChallengeResponse(email);

  try {
    if (!await isOperationalFeatureEnabled(admin as unknown as FeatureFlagClient, "email_enabled")) return neutralChallengeResponse(email);
    const ipAllowed = await consumeRateLimit(admin, { scope: "otp_request", keyHash: requestRateKey(request, "otp-request-ip"), limit: 20, windowSeconds: 3_600 });
    if (!ipAllowed) return neutralChallengeResponse(email);
    const code = generateParentCode();
    const codeHash = hashParentSecret(code);
    const { data: accountId, error } = await admin.rpc("create_parent_otp", { p_email: email, p_code_hash: codeHash, p_expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString() });
    if (!error && accountId) {
      const template = await getParentOtpEmailTemplate(admin);
      const message = renderParentOtpEmail(template, code);
      await sendParentOtpEmail(email, message);
    }
  } catch {
    // Do not reveal whether an e-mail exists or whether delivery infrastructure is configured.
  }
  return neutralChallengeResponse(email);
}
