import { after, NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { generateParentCode, hashParentSecret, normalizeParentEmail, parentEmailSchema, sealParentChallengeEmail } from "@/server/auth/parent";
import {
  sendParentOtpEmail,
  sendParentOtpV2Email,
} from "@/server/email/provider";
import {
  authorizeParentOtpV2,
  completeParentOtpV2,
  getParentOtpEmailTemplate,
  prepareParentOtpV2,
  renderParentOtpEmail,
  renderParentOtpV2,
} from "@/server/email/otp";
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

async function deliverPreparedParentOtp(
  admin: NonNullable<ReturnType<typeof getSupabaseAdminClient>>,
  preparation: Extract<
    Awaited<ReturnType<typeof prepareParentOtpV2>>,
    { status: "prepared" }
  >,
  email: string,
  code: string,
  appBaseUrl: string,
) {
  const appClient = admin.schema("app");
  try {
    if (!await authorizeParentOtpV2(appClient, preparation.deliveryAttemptId)) {
      await completeParentOtpV2(
        appClient,
        preparation.deliveryAttemptId,
        {
          outcome: "disabled",
          errorCode: "send_authorization_denied",
        },
      );
      return;
    }
    let message: ReturnType<typeof renderParentOtpV2>;
    try {
      message = renderParentOtpV2(preparation, code, appBaseUrl);
    } catch {
      await completeParentOtpV2(
        appClient,
        preparation.deliveryAttemptId,
        {
          outcome: "render_failed",
          errorCode: "render_failed",
        },
      );
      return;
    }
    const delivery = await sendParentOtpV2Email({
      deliveryAttemptId: preparation.deliveryAttemptId,
      recipientEmail: email,
      subject: message.subject,
      text: message.text,
      html: message.html,
      fromName: message.fromName,
      fromEmail: message.fromEmail,
      replyToEmail: message.replyToEmail,
    });
    if (delivery.delivered) {
      await completeParentOtpV2(
        appClient,
        preparation.deliveryAttemptId,
        {
          outcome: "accepted",
          providerMessageId: delivery.providerMessageId,
        },
      );
      return;
    }
    await completeParentOtpV2(
      appClient,
      preparation.deliveryAttemptId,
      {
        outcome: delivery.reason,
        errorCode: delivery.reason,
      },
    );
  } catch {
    // The health gate reports an uncompleted attempt. Never retry a transient
    // OTP send automatically and never log the code or recipient.
  }
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
    const expiresAt = new Date(
      Date.now() + 10 * 60 * 1_000,
    ).toISOString();
    const preparation = await prepareParentOtpV2(
      admin.schema("app"),
      email,
      codeHash,
      expiresAt,
    );
    if (preparation.status === "prepared") {
      const appBaseUrl = getServerEnv().APP_BASE_URL;
      after(() => deliverPreparedParentOtp(
        admin,
        preparation,
        email,
        code,
        appBaseUrl,
      ));
    } else if (preparation.status === "unavailable") {
      const { data: accountId, error } = await admin.rpc(
        "create_parent_otp",
        {
          p_email: email,
          p_code_hash: codeHash,
          p_expires_at: expiresAt,
        },
      );
      after(async () => {
        if (error || !accountId) return;
        try {
          const template = await getParentOtpEmailTemplate(admin);
          const message = renderParentOtpEmail(template, code);
          await sendParentOtpEmail(email, message);
        } catch {
          // Legacy fallback is only valid before the immutable v2 cutover.
        }
      });
    } else {
      after(async () => undefined);
    }
  } catch {
    // Do not reveal whether an e-mail exists or whether delivery infrastructure is configured.
  }
  return neutralChallengeResponse(email);
}
