import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";

const mocks = vi.hoisted(() => ({
  after: vi.fn(),
  callbacks: [] as Array<() => unknown>,
  admin: vi.fn(),
  featureEnabled: vi.fn(),
  rateAllowed: vi.fn(),
  prepare: vi.fn(),
  deliver: vi.fn(),
  challengeCookie: undefined as string | undefined,
}));

vi.mock("next/server", async (importOriginal) => {
  const original = await importOriginal<typeof import("next/server")>();
  return { ...original, after: mocks.after };
});
vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: () => mocks.challengeCookie
      ? { value: mocks.challengeCookie }
      : undefined,
  }),
}));
vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({
    APP_BASE_URL: "https://tenue.example",
    PARENT_TOKEN_PEPPER: "p".repeat(32),
  }),
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));
vi.mock("@/server/operations/feature-flags", () => ({
  isOperationalFeatureEnabled: mocks.featureEnabled,
}));
vi.mock("@/server/auth/rate-limit", () => ({
  consumeRateLimit: mocks.rateAllowed,
  requestRateKey: () => "safe-rate-key",
}));
vi.mock("@/server/email/otp", () => ({
  prepareParentOtpV3: mocks.prepare,
}));
vi.mock("@/server/email/otp-delivery", () => ({
  deliverPreparedParentOtpV3: mocks.deliver,
}));

import { POST } from "./route";
import {
  openParentChallengeContext,
  sealParentChallengeContext,
  type ParentChallengeContext,
} from "@/server/auth/parent";

const neutralBody = {
  message: "Als dit e-mailadres bij ons bekend is, is een code verzonden.",
};
const challengeId = "11111111-1111-4111-8111-111111111111";
const deliveryAttemptId = "22222222-2222-4222-8222-222222222222";
const expiresAt = "2099-08-21T03:00:00.000Z";
const cooldownUntil = "2099-08-21T02:51:30.000Z";

function request(body: Record<string, unknown> = {
  email: "ouder@example.nl",
}) {
  return new Request(
    "https://tenue.example/api/parent-auth/request-code",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        origin: "https://tenue.example",
        host: "tenue.example",
        "sec-fetch-site": "same-origin",
        "x-duindorp-csrf": "same-origin",
      },
      body: JSON.stringify(body),
    },
  );
}

describe("POST /api/parent-auth/request-code", () => {
  beforeEach(() => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    mocks.challengeCookie = undefined;
    mocks.callbacks.length = 0;
    mocks.after.mockReset().mockImplementation(
      (callback: () => unknown) => mocks.callbacks.push(callback),
    );
    mocks.admin.mockReset().mockReturnValue({
      schema: () => ({ rpc: vi.fn() }),
    });
    mocks.featureEnabled.mockReset().mockResolvedValue(true);
    mocks.rateAllowed.mockReset().mockResolvedValue(true);
    mocks.prepare.mockReset().mockResolvedValue({
      status: "prepared",
      challengeId,
      expiresAt,
      cooldownUntil,
      reused: false,
      deliveryAttemptId,
      expiresInMinutes: 10,
    });
    mocks.deliver.mockReset().mockResolvedValue({
      outcome: "provider_accepted",
    });
  });

  it("antwoordt neutraal en levert daarna dezelfde prepared challenge", async () => {
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(neutralBody);
    expect(response.headers.get("set-cookie")).toContain(
      "duindorp_parent_challenge=",
    );
    expect(mocks.prepare).toHaveBeenCalledWith(
      expect.anything(),
      "ouder@example.nl",
      expect.any(String),
      expect.stringMatching(/^[0-9a-f]{64}$/u),
      false,
      null,
    );
    expect(mocks.deliver).not.toHaveBeenCalled();
    await mocks.callbacks[0]();
    expect(mocks.deliver).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ challengeId, deliveryAttemptId }),
      "ouder@example.nl",
      "https://tenue.example",
    );
  });

  it("gebruikt alleen een geldig ondertekend stagingvoorstel", async () => {
    const fixtureDigest = "a".repeat(64);
    const proof = createHmac("sha256", "p".repeat(32)).update(
      `parent-login-staging-challenge:v1\0${fixtureDigest}\0${challengeId}`,
      "utf8",
    ).digest("hex");
    const original = request();
    const signed = new Request(original, {
      headers: {
        ...Object.fromEntries(original.headers),
        "x-duindorp-staging-challenge-id": challengeId,
        "x-duindorp-staging-challenge-proof": proof,
        "x-duindorp-staging-fixture-digest": fixtureDigest,
      },
    });
    process.env.APP_ENVIRONMENT = "staging";
    process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED = "true";
    try {
      await POST(signed);
      expect(mocks.prepare).toHaveBeenCalledWith(
        expect.anything(),
        "ouder@example.nl",
        challengeId,
        expect.stringMatching(/^[0-9a-f]{64}$/u),
        false,
        null,
      );
    } finally {
      delete process.env.APP_ENVIRONMENT;
      delete process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED;
    }
  });

  it.each(["cooldown", "rate_limited"] as const)(
    "houdt bij %s dezelfde challenge-context zonder een mail te sturen",
    async (status) => {
      mocks.prepare.mockResolvedValueOnce({
        status,
        challengeId,
        expiresAt,
        cooldownUntil,
      });
      const response = await POST(request());
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual(neutralBody);
      expect(mocks.deliver).not.toHaveBeenCalled();
      expect(mocks.callbacks).toHaveLength(0);
    },
  );

  it.each(["ineligible", "blocked", "unavailable"] as const)(
    "geeft voor interne status %s exact hetzelfde neutrale antwoord",
    async (status) => {
      mocks.prepare.mockResolvedValueOnce({ status });
      const response = await POST(request());
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual(neutralBody);
      expect(mocks.deliver).not.toHaveBeenCalled();
    },
  );

  it("resendt via de opaque cookie zonder het volledige adres in de body", async () => {
    const context: ParentChallengeContext = {
      version: 3,
      email: "ouder@example.nl",
      challengeId,
      expiresAt,
      cooldownUntil,
    };
    mocks.challengeCookie = sealParentChallengeContext(context);
    mocks.prepare.mockResolvedValueOnce({
      status: "prepared",
      ...context,
      reused: true,
      deliveryAttemptId,
      expiresInMinutes: 10,
    });
    const response = await POST(request({ resend: true }));
    expect(response.status).toBe(202);
    expect(mocks.prepare).toHaveBeenCalledWith(
      expect.anything(),
      "ouder@example.nl",
      expect.any(String),
      expect.any(String),
      false,
      null,
    );
  });

  it("staat forceNew uitsluitend toe als cookiegebonden resend", async () => {
    const context: ParentChallengeContext = {
      version: 3,
      email: "ouder@example.nl",
      challengeId,
      expiresAt,
      cooldownUntil,
    };
    mocks.challengeCookie = sealParentChallengeContext(context);
    const response = await POST(request({ resend: true, forceNew: true }));
    expect(response.status).toBe(202);
    expect(mocks.prepare).toHaveBeenCalledWith(
      expect.anything(),
      "ouder@example.nl",
      expect.any(String),
      expect.any(String),
      true,
      challengeId,
    );
  });

  it("houdt bij een stale forceNew-cookie exact die oude context vast", async () => {
    const staleContext: ParentChallengeContext = {
      version: 3,
      email: "ouder@example.nl",
      challengeId,
      expiresAt,
      cooldownUntil,
    };
    mocks.challengeCookie = sealParentChallengeContext(staleContext);
    mocks.prepare.mockResolvedValueOnce({ status: "ineligible" });
    const response = await POST(request({ resend: true, forceNew: true }));
    expect(response.status).toBe(202);
    expect(mocks.prepare).toHaveBeenCalledWith(
      expect.anything(),
      "ouder@example.nl",
      expect.any(String),
      expect.any(String),
      true,
      challengeId,
    );
    const sealedContext = response.headers.get("set-cookie")
      ?.match(/duindorp_parent_challenge=([^;]+)/u)?.[1];
    expect(openParentChallengeContext(sealedContext ?? "")).toMatchObject({
      challengeId,
      email: "ouder@example.nl",
    });
    expect(mocks.deliver).not.toHaveBeenCalled();
  });

  it("weigert een losse e-mailaanvraag die forceNew probeert te zetten", async () => {
    const response = await POST(request({
      email: "ouder@example.nl",
      forceNew: true,
    }));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "Voer een geldig e-mailadres in.",
    });
    expect(mocks.prepare).not.toHaveBeenCalled();
  });

  it("redigeert ook een voorbereidingsfout naar dezelfde 202", async () => {
    mocks.prepare.mockRejectedValueOnce(new Error("database details"));
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(neutralBody);
  });
});
