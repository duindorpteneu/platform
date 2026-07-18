import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  config: vi.fn(),
  origin: vi.fn(),
  start: vi.fn(),
  session: vi.fn(),
  admin: vi.fn(),
}));

vi.mock("@/server/payments/mollie-service", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/server/payments/mollie-service")>();
  return {
    ...actual,
    getMollieRuntimeConfig: mocks.config,
    hasTrustedPaymentOrigin: mocks.origin,
    startMollieCheckout: mocks.start,
  };
});
vi.mock("@/server/auth/parent-session", () => ({ getParentSession: mocks.session }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));

import { POST } from "@/app/api/payments/mollie/create/route";

const orderId = "00000000-0000-4000-8000-000000000002";

function request(body: unknown) {
  return new Request("https://tenue.example/api/payments/mollie/create", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://tenue.example" },
    body: JSON.stringify(body),
  });
}

describe("Mollie create-route", () => {
  beforeEach(() => {
    mocks.config.mockReset().mockReturnValue({ enabled: true, apiKey: "test_000000000000", appBaseUrl: "https://tenue.example" });
    mocks.origin.mockReset().mockReturnValue(true);
    mocks.start.mockReset().mockResolvedValue({ checkoutUrl: "https://checkout.mollie.com/pay/test" });
    mocks.session.mockReset().mockResolvedValue({ tokenHash: "a".repeat(64) });
    mocks.admin.mockReset().mockReturnValue({ rpc: vi.fn() });
  });

  it("mapt een ongeldige env-configuratie altijd naar een neutrale 503", async () => {
    mocks.config.mockImplementation(() => { throw new Error("invalid env"); });
    const response = await POST(request({ orderId }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Online betalen is tijdelijk niet beschikbaar." });
    expect(mocks.start).not.toHaveBeenCalled();
  });

  it("weigert een bedrag uit de browser", async () => {
    const response = await POST(request({ orderId, amountCents: 1 }));
    expect(response.status).toBe(400);
    expect(mocks.start).not.toHaveBeenCalled();
  });

  it("retourneert uitsluitend de beveiligde hosted checkout", async () => {
    const response = await POST(request({ orderId }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ checkoutUrl: "https://checkout.mollie.com/pay/test" });
    expect(mocks.start).toHaveBeenCalledWith(expect.objectContaining({ orderId, tokenHash: "a".repeat(64) }), expect.any(Object));
  });
});
