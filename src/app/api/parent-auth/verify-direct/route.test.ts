import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  rpc: vi.fn(),
  rateAllowed: vi.fn(),
  cookieSet: vi.fn(),
}));

vi.mock("next/headers", () => ({
  cookies: async () => ({ set: mocks.cookieSet }),
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
  deriveParentDirectCredential,
  PARENT_SESSION_COOKIE_MAX_AGE_SECONDS,
  PARENT_SESSION_DATABASE_MAX_AGE_SECONDS,
} from "@/server/auth/parent";

const challengeId = "11111111-1111-4111-8111-111111111111";

function request(credential: string) {
  return new Request("https://tenue.example/api/parent-auth/verify-direct", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
    },
    body: JSON.stringify({ credential }),
  });
}

describe("POST /api/parent-auth/verify-direct", () => {
  beforeEach(() => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.cookieSet.mockReset();
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

  it("verifieert het HMAC-bewijs en consumeert dezelfde challenge", async () => {
    const startedAt = Date.now();
    const response = await POST(request(
      deriveParentDirectCredential(challengeId),
    ));
    const completedAt = Date.now();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "consume_parent_login_challenge_v3",
      expect.objectContaining({
        p_challenge_id: challengeId,
        p_credential_kind: "direct",
        p_code_hash: null,
      }),
    );
    expect(mocks.cookieSet).toHaveBeenCalledWith(
      "duindorp_parent_session",
      expect.any(String),
      expect.objectContaining({
        httpOnly: true,
        maxAge: PARENT_SESSION_COOKIE_MAX_AGE_SECONDS,
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

  it("weigert een gewijzigd bewijs vóór consumptie", async () => {
    const credential = deriveParentDirectCredential(challengeId);
    const replacement = credential.endsWith("x") ? "y" : "x";
    const response = await POST(request(
      `${credential.slice(0, -1)}${replacement}`,
    ));
    expect(response.status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.cookieSet).not.toHaveBeenCalled();
  });

  it("laat replay door de atomische databaseconsumptie afwijzen", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { status: "invalid" },
      error: null,
    });
    const response = await POST(request(
      deriveParentDirectCredential(challengeId),
    ));
    expect(response.status).toBe(401);
    expect(mocks.cookieSet).not.toHaveBeenCalled();
  });
});
