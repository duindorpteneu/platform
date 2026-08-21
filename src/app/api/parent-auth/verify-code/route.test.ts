import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  rpc: vi.fn(),
  rateAllowed: vi.fn(),
  cookieGet: vi.fn(),
  cookieSet: vi.fn(),
}));

vi.mock("next/headers", () => ({
  cookies: async () => ({ get: mocks.cookieGet, set: mocks.cookieSet }),
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));
vi.mock("@/server/auth/rate-limit", () => ({
  consumeRateLimit: mocks.rateAllowed,
  requestRateKey: () => "ip-key",
  valueRateKey: () => "challenge-key",
}));

import { POST } from "./route";
import {
  PARENT_SESSION_COOKIE_MAX_AGE_SECONDS,
  PARENT_SESSION_DATABASE_MAX_AGE_SECONDS,
  sealParentChallengeContext,
} from "@/server/auth/parent";

const challengeId = "11111111-1111-4111-8111-111111111111";

function request(code = "123456") {
  return new Request("https://tenue.example/api/parent-auth/verify-code", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
    },
    body: JSON.stringify({ code }),
  });
}

describe("POST /api/parent-auth/verify-code", () => {
  beforeEach(() => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.cookieSet.mockReset();
    mocks.cookieGet.mockReset().mockReturnValue({
      value: sealParentChallengeContext({
        version: 3,
        email: "ouder@example.nl",
        challengeId,
        expiresAt: "2099-08-21T03:00:00.000Z",
        cooldownUntil: "2099-08-21T02:51:30.000Z",
      }),
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        status: "verified",
        parentAccountId: "22222222-2222-4222-8222-222222222222",
      },
      error: null,
    });
    mocks.admin.mockReset().mockReturnValue({ rpc: mocks.rpc });
    mocks.rateAllowed.mockReset().mockResolvedValue(true);
  });

  it("consumeert challenge en creëert de sessie atomair in één RPC", async () => {
    const startedAt = Date.now();
    const response = await POST(request());
    const completedAt = Date.now();
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "consume_parent_login_challenge_v4",
      expect.objectContaining({
        p_challenge_id: challengeId,
        p_credential_kind: "code",
        p_acceptance_correlation_hash: null,
        p_code_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
        p_session_token_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
      }),
    );
    expect(mocks.cookieSet).toHaveBeenCalledWith(
      "duindorp_parent_session",
      expect.any(String),
      expect.objectContaining({
        httpOnly: true,
        maxAge: PARENT_SESSION_COOKIE_MAX_AGE_SECONDS,
        sameSite: "lax",
      }),
    );
    const rpcInput = mocks.rpc.mock.calls[0]?.[1] as {
      p_session_expires_at: string;
    };
    const expiresAt = Date.parse(rpcInput.p_session_expires_at);
    expect(expiresAt).toBeGreaterThanOrEqual(
      startedAt + PARENT_SESSION_DATABASE_MAX_AGE_SECONDS * 1_000,
    );
    expect(expiresAt).toBeLessThanOrEqual(
      completedAt + PARENT_SESSION_DATABASE_MAX_AGE_SECONDS * 1_000,
    );
  });

  it("bindt een geldig ondertekende stagingverificatie atomair", async () => {
    const fixtureDigest = "a".repeat(64);
    const correlationId = "33333333-3333-4333-8333-333333333333";
    const secret = process.env.PARENT_TOKEN_PEPPER!;
    const proof = createHmac("sha256", secret).update(
      `parent-login-staging-session:v1\0${fixtureDigest}\0${correlationId}`,
      "utf8",
    ).digest("hex");
    const original = request();
    process.env.APP_ENVIRONMENT = "staging";
    process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED = "true";
    try {
      await POST(new Request(original, { headers: {
        ...Object.fromEntries(original.headers),
        "x-duindorp-staging-fixture-digest": fixtureDigest,
        "x-duindorp-staging-session-id": correlationId,
        "x-duindorp-staging-session-proof": proof,
      } }));
      expect(mocks.rpc).toHaveBeenCalledWith(
        "consume_parent_login_challenge_v4",
        expect.objectContaining({
          p_acceptance_correlation_hash: createHmac("sha256", secret).update(
            `parent-login-staging-session-correlation:v1\0${fixtureDigest}\0${correlationId}`,
            "utf8",
          ).digest("hex"),
        }),
      );
    } finally {
      delete process.env.APP_ENVIRONMENT;
      delete process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED;
    }
  });

  it("geeft resterende pogingen alleen vanuit een gebonden challenge terug", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { status: "invalid", attemptsRemaining: 3 },
      error: null,
    });
    const response = await POST(request("000000"));
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({
      error: "Deze code klopt niet of is niet meer geldig.",
      attemptsRemaining: 3,
    });
    expect(mocks.cookieSet).not.toHaveBeenCalled();
  });

  it("blokkeert na de rate limit zonder de RPC aan te roepen", async () => {
    mocks.rateAllowed.mockResolvedValueOnce(false);
    const response = await POST(request());
    expect(response.status).toBe(429);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
