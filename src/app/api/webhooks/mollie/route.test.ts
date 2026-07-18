import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  reconcile: vi.fn(),
  config: vi.fn(),
  admin: vi.fn(),
}));

vi.mock("@/server/payments/mollie-service", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/server/payments/mollie-service")>();
  return { ...actual, reconcileMollieWebhook: mocks.reconcile, getMollieRuntimeConfig: mocks.config };
});
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));

import { MollieServiceError } from "@/server/payments/mollie-service";
import { POST } from "@/app/api/webhooks/mollie/route";

describe("Mollie classic webhookroute", () => {
  beforeEach(() => {
    mocks.reconcile.mockReset().mockResolvedValue({ effect: "paid" });
    mocks.config.mockReset().mockReturnValue({ enabled: true, apiKey: "test_000000000000", appBaseUrl: "https://tenue.example" });
    mocks.admin.mockReset().mockReturnValue({ rpc: vi.fn() });
  });

  it("accepteert het klassieke form-id en haalt daarna providerstatus op", async () => {
    const response = await POST(new Request("https://tenue.example/api/webhooks/mollie", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: "id=tr_test123",
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ received: true });
    expect(mocks.reconcile).toHaveBeenCalledWith("tr_test123", expect.objectContaining({ config: expect.any(Object) }));
  });

  it("weigert een JSON-webhook", async () => {
    const response = await POST(new Request("https://tenue.example/api/webhooks/mollie", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: "tr_test123" }),
    }));

    expect(response.status).toBe(400);
    expect(mocks.reconcile).not.toHaveBeenCalled();
  });

  it("geeft een tijdelijke databasefout terug voor Mollie-retry", async () => {
    mocks.reconcile.mockRejectedValue(new MollieServiceError("DATABASE_UNAVAILABLE", true));
    const response = await POST(new Request("https://tenue.example/api/webhooks/mollie", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: "id=tr_test123",
    }));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ received: false });
  });

  it("mapt een ongeldige serverconfiguratie naar een retrybare 503", async () => {
    mocks.config.mockImplementation(() => { throw new Error("invalid env"); });
    const response = await POST(new Request("https://tenue.example/api/webhooks/mollie", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: "id=tr_test123",
    }));

    expect(response.status).toBe(503);
    expect(mocks.reconcile).not.toHaveBeenCalled();
  });
});
