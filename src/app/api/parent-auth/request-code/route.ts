import { NextResponse } from "next/server";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { generateParentCode, hashParentSecret, normalizeParentEmail, parentEmailSchema } from "@/server/auth/parent";
import { sendParentOtpEmail } from "@/server/email/sendgrid";
import { consumeRateLimit, requestRateKey } from "@/server/auth/rate-limit";
import { guardBrowserMutation } from "@/server/security/route-guard";
import { isOperationalFeatureEnabled, type FeatureFlagClient } from "@/server/operations/feature-flags";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const neutralResponse = { message: "Als dit e-mailadres bij ons bekend is, is een code verzonden." };

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: { allowedContentTypes: ["application/json"], maxBytes: 4_096 } }); if (guarded) return guarded;
  const parsed = parentEmailSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Voer een geldig e-mailadres in." }, { status: 400 });

  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json(neutralResponse, { status: 202 });

  try {
    if (!await isOperationalFeatureEnabled(admin as unknown as FeatureFlagClient, "email_enabled")) return NextResponse.json(neutralResponse, { status: 202 });
    const email = normalizeParentEmail(parsed.data.email);
    const ipAllowed = await consumeRateLimit(admin, { scope: "otp_request", keyHash: requestRateKey(request, "otp-request-ip"), limit: 20, windowSeconds: 3_600 });
    if (!ipAllowed) return NextResponse.json(neutralResponse, { status: 202 });
    const code = generateParentCode();
    const codeHash = hashParentSecret(code);
    const { data: accountId, error } = await admin.rpc("create_parent_otp", { p_email: email, p_code_hash: codeHash, p_expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString() });
    if (!error && accountId) await sendParentOtpEmail(email, code);
  } catch {
    // Do not reveal whether an e-mail exists or whether delivery infrastructure is configured.
  }
  return NextResponse.json(neutralResponse, { status: 202 });
}
