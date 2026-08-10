import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  reset: vi.fn(),
  rate: vi.fn(),
}));

vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({
    APP_BASE_URL: "https://tenue.example",
    PARENT_TOKEN_PEPPER: "p".repeat(32),
  }),
}));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/auth/rate-limit", () => ({
  consumeRateLimit: mocks.rate,
  requestRateKey: () => "a".repeat(64),
  valueRateKey: () => "b".repeat(64),
}));

import { POST } from "./route";

function recoveryRequest(email = " E2E@Example.nl ", origin = "https://tenue.example") {
  return new Request("https://tenue.example/api/staff-auth/password-recovery", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin,
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
    },
    body: JSON.stringify({ email }),
  });
}

describe("POST /api/staff-auth/password-recovery", () => {
  beforeEach(() => {
    mocks.reset.mockReset().mockResolvedValue({ data: {}, error: null });
    mocks.rate.mockReset().mockResolvedValue(true);
    mocks.admin.mockReset().mockReturnValue({
      auth: { resetPasswordForEmail: mocks.reset },
      schema: () => ({ rpc: vi.fn() }),
    });
  });

  it("normaliseert het adres en bindt herstel aan de canonical staffroute", async () => {
    const response = await POST(recoveryRequest());
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      message: "Als dit e-mailadres bij een medewerkersaccount hoort, is een herstellink verzonden.",
    });
    expect(mocks.reset).toHaveBeenCalledWith("e2e@example.nl", {
      redirectTo: "https://tenue.example/staff/reset-password",
    });
    expect(mocks.rate).toHaveBeenCalledTimes(2);
  });

  it("antwoordt bij rate-limit en providerfout hetzelfde zonder accountinformatie", async () => {
    mocks.rate.mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    const limited = await POST(recoveryRequest("onbekend@example.nl"));
    expect(limited.status).toBe(202);
    expect(mocks.reset).not.toHaveBeenCalled();

    mocks.rate.mockReset().mockResolvedValue(true);
    mocks.reset.mockRejectedValueOnce(new Error("provider details"));
    const failed = await POST(recoveryRequest("onbekend@example.nl"));
    expect(failed.status).toBe(202);
    expect(await failed.json()).toEqual(await limited.json());
  });

  it("weigert ongeldige invoer en cross-site requests vóór de provider", async () => {
    expect((await POST(recoveryRequest("geen-adres"))).status).toBe(400);
    expect((await POST(recoveryRequest("e2e@example.nl", "https://evil.example"))).status).toBe(403);
    expect(mocks.reset).not.toHaveBeenCalled();
  });
});
