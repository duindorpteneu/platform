import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { z } from "zod";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import {
  generateParentSessionToken,
  hashParentSecret,
  parentDirectCredentialInputSchema,
  verifyParentDirectCredential,
} from "@/server/auth/parent";
import {
  consumeRateLimit,
  requestRateKey,
  valueRateKey,
} from "@/server/auth/rate-limit";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const consumeResultSchema = z.object({
  status: z.string(),
  parentAccountId: z.string().uuid().optional(),
}).passthrough();
const securityHeaders = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
};

function failure(status = 401) {
  return NextResponse.json(
    { error: "Deze inloglink klopt niet of is niet meer geldig." },
    { status, headers: securityHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) {
    guarded.headers.set("Cache-Control", "no-store");
    guarded.headers.set("Referrer-Policy", "no-referrer");
    return guarded;
  }
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) {
    body.response.headers.set("Cache-Control", "no-store");
    body.response.headers.set("Referrer-Policy", "no-referrer");
    return body.response;
  }
  const parsed = parentDirectCredentialInputSchema.safeParse(body.data);
  if (!parsed.success) return failure(400);

  const challengeId = verifyParentDirectCredential(parsed.data.credential);
  const admin = getSupabaseAdminClient();
  if (!admin) {
    return NextResponse.json(
      { error: "Inloggen is tijdelijk niet beschikbaar." },
      { status: 503, headers: securityHeaders },
    );
  }
  const ipAllowed = await consumeRateLimit(admin, {
    scope: "otp_verify",
    keyHash: requestRateKey(request, "otp-direct-ip"),
    limit: 30,
    windowSeconds: 3_600,
  });
  if (!ipAllowed || !challengeId) return failure(ipAllowed ? 401 : 429);
  const challengeAllowed = await consumeRateLimit(admin, {
    scope: "otp_verify",
    keyHash: valueRateKey("otp-direct-challenge", challengeId),
    limit: 15,
    windowSeconds: 3_600,
  });
  if (!challengeAllowed) return failure(429);

  const sessionToken = generateParentSessionToken();
  const { data, error } = await admin.rpc(
    "consume_parent_login_challenge_v3",
    {
      p_challenge_id: challengeId,
      p_credential_kind: "direct",
      p_code_hash: null,
      p_session_token_hash: hashParentSecret(sessionToken),
      p_session_expires_at: new Date(
        Date.now() + 30 * 24 * 60 * 60 * 1_000,
      ).toISOString(),
    },
  );
  const result = consumeResultSchema.safeParse(data);
  if (error || !result.success || result.data.status !== "verified") {
    return failure();
  }

  const cookieStore = await cookies();
  cookieStore.set("duindorp_parent_session", sessionToken, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 30 * 24 * 60 * 60,
  });
  cookieStore.set("duindorp_parent_challenge", "", {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 0,
  });
  return NextResponse.json(
    { status: "verified" },
    { status: 200, headers: securityHeaders },
  );
}
