import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { z } from "zod";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import {
  generateParentSessionToken,
  hashParentSecret,
  openParentChallengeContext,
  parentCodeInputSchema,
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
  attemptsRemaining: z.number().int().min(0).max(5).optional(),
}).passthrough();

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = parentCodeInputSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Voer de zescijferige code in." },
      { status: 400 },
    );
  }
  const cookieStore = await cookies();
  const context = openParentChallengeContext(
    cookieStore.get("duindorp_parent_challenge")?.value ?? "",
  );
  if (!context) {
    return NextResponse.json(
      { error: "Vraag eerst een nieuwe verificatiecode aan." },
      { status: 401 },
    );
  }
  const admin = getSupabaseAdminClient();
  if (!admin) {
    return NextResponse.json(
      { error: "Inloggen is tijdelijk niet beschikbaar." },
      { status: 503 },
    );
  }

  const [ipAllowed, challengeAllowed] = await Promise.all([
    consumeRateLimit(admin, {
      scope: "otp_verify",
      keyHash: requestRateKey(request, "otp-verify-ip"),
      limit: 30,
      windowSeconds: 3_600,
    }),
    consumeRateLimit(admin, {
      scope: "otp_verify",
      keyHash: valueRateKey("otp-verify-challenge", context.challengeId),
      limit: 15,
      windowSeconds: 3_600,
    }),
  ]);
  if (!ipAllowed || !challengeAllowed) {
    return NextResponse.json(
      { error: "Te veel verificatiepogingen. Vraag later een nieuwe code aan." },
      { status: 429 },
    );
  }

  const sessionToken = generateParentSessionToken();
  const { data, error } = await admin.rpc(
    "consume_parent_login_challenge_v3",
    {
      p_challenge_id: context.challengeId,
      p_credential_kind: "code",
      p_code_hash: hashParentSecret(parsed.data.code),
      p_session_token_hash: hashParentSecret(sessionToken),
      p_session_expires_at: new Date(
        Date.now() + 30 * 24 * 60 * 60 * 1_000,
      ).toISOString(),
    },
  );
  const result = consumeResultSchema.safeParse(data);
  if (error || !result.success || result.data.status !== "verified") {
    return NextResponse.json(
      {
        error: "Deze code klopt niet of is niet meer geldig.",
        ...(result.success
          && typeof result.data.attemptsRemaining === "number"
          && result.data.attemptsRemaining > 0
          ? { attemptsRemaining: result.data.attemptsRemaining }
          : {}),
      },
      { status: 401 },
    );
  }

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
  return NextResponse.json({ status: "verified" }, { status: 200 });
}
