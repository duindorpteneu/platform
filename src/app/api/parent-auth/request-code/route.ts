import { after, NextResponse } from "next/server";
import { cookies } from "next/headers";
import { getServerEnv } from "@/lib/env";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import {
  createNeutralParentChallengeContext,
  deriveParentCode,
  generateParentChallengeId,
  hashParentSecret,
  normalizeParentEmail,
  openParentChallengeContext,
  parentOtpRequestSchema,
  sealParentChallengeContext,
  stagingAcceptanceChallengeId,
  type ParentChallengeContext,
} from "@/server/auth/parent";
import { prepareParentOtpV3 } from "@/server/email/otp";
import { deliverPreparedParentOtpV3 } from "@/server/email/otp-delivery";
import { consumeRateLimit, requestRateKey } from "@/server/auth/rate-limit";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import {
  isOperationalFeatureEnabled,
  type FeatureFlagClient,
} from "@/server/operations/feature-flags";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const neutralResponse = {
  message: "Als dit e-mailadres bij ons bekend is, is een code verzonden.",
};

function neutralChallengeResponse(context: ParentChallengeContext) {
  const response = NextResponse.json(neutralResponse, { status: 202 });
  response.cookies.set(
    "duindorp_parent_challenge",
    sealParentChallengeContext(context),
    {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "lax",
      path: "/",
      maxAge: 10 * 60,
    },
  );
  return response;
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = parentOtpRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Voer een geldig e-mailadres in." },
      { status: 400 },
    );
  }

  const cookieStore = await cookies();
  const previousContext = openParentChallengeContext(
    cookieStore.get("duindorp_parent_challenge")?.value ?? "",
  );
  const isResend = "resend" in parsed.data;
  if (isResend && !previousContext) {
    return NextResponse.json(
      { error: "Vraag eerst een nieuwe verificatiecode aan." },
      { status: 401 },
    );
  }
  const email = isResend
    ? previousContext!.email
    : normalizeParentEmail("email" in parsed.data ? parsed.data.email : "");
  const forceNew = "resend" in parsed.data
    && parsed.data.forceNew === true;
  let responseContext = previousContext?.email === email
    ? previousContext
    : createNeutralParentChallengeContext(email);
  const admin = getSupabaseAdminClient();
  if (!admin) return neutralChallengeResponse(responseContext);

  try {
    if (!await isOperationalFeatureEnabled(
      admin as unknown as FeatureFlagClient,
      "email_enabled",
    )) {
      return neutralChallengeResponse(responseContext);
    }
    const stagingChallengeId = stagingAcceptanceChallengeId(request);
    const ipAllowed = await consumeRateLimit(admin, {
      scope: "otp_request",
      keyHash: requestRateKey(request, "otp-request-ip"),
      limit: 20,
      windowSeconds: 3_600,
    });
    if (!ipAllowed) return neutralChallengeResponse(responseContext);

    const proposedChallengeId = stagingChallengeId ?? generateParentChallengeId();
    const proposedCode = deriveParentCode(proposedChallengeId);
    const preparation = await prepareParentOtpV3(
      admin.schema("app"),
      email,
      proposedChallengeId,
      hashParentSecret(proposedCode),
      forceNew,
      forceNew ? previousContext!.challengeId : null,
    );
    if (
      preparation.status === "prepared"
      || preparation.status === "cooldown"
      || preparation.status === "rate_limited"
    ) {
      responseContext = {
        version: 3,
        email,
        challengeId: preparation.challengeId,
        expiresAt: preparation.expiresAt,
        cooldownUntil: preparation.cooldownUntil,
      };
    }
    if (preparation.status === "prepared") {
      after(() => deliverPreparedParentOtpV3(
        admin,
        preparation,
        email,
        getServerEnv().APP_BASE_URL,
      ));
    }
  } catch {
    // Preserve the same status, body and cookie shape for every eligible state.
  }
  return neutralChallengeResponse(responseContext);
}
