import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: mocks.serverClient,
}));

import { POST } from "./route";

const orderId = "10000000-0000-4000-8000-000000000001";
const requestId = "20000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/payments/manual", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

const validBody = {
  orderId,
  method: "cash",
  amountCents: 12_500,
  reason: "Contant volledig ontvangen",
  requestId,
} as const;

describe("POST /api/payments/manual", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        paymentId: "30000000-0000-4000-8000-000000000001",
        status: "paid",
        amountCents: 12_500,
        qrStatus: "inactive_until_allocated",
        reused: false,
      },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("gebruikt uitsluitend het beheerder/AAL2-databasecontract zonder QR-geheim", async () => {
    const response = await POST(request(validBody));

    expect(response.status).toBe(201);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith("record_manual_payment_v2", {
      p_order_id: orderId,
      p_method: "cash",
      p_amount_cents: 12_500,
      p_reason: validBody.reason,
      p_request_id: requestId,
    });
    expect(JSON.stringify(mocks.rpc.mock.calls)).not.toContain("token");
  });

  it("laat kledingcommissie de betaal-RPC niet bereiken", async () => {
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );

    const response = await POST(request(validBody));

    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een database-AAL1-weigering naar 403", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "42501", message: "STAFF_AUTHORIZATION_REQUIRED" },
    });

    const response = await POST(request(validBody));

    expect(response.status).toBe(403);
  });

  it("weigert pin als de compatibiliteitsflag uitstaat", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "55000", message: "LEGACY_CARD_PAYMENT_DISABLED" },
    });

    const response = await POST(request({ ...validBody, method: "card" }));

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "Pinregistratie is uitgeschakeld; gebruik Mollie of registreer kas.",
    });
  });

  it("registreert geen handmatige betaling zonder complete pakketmaten", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "23514", message: "PACKAGE_SIZES_REQUIRED" } });
    const response = await POST(request(validBody));
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "Vul eerst alle verplichte pakketmaten in.", code: "PACKAGE_SIZES_REQUIRED" });
  });

  it("lekt bij een conflict geen database- of redeninhoud", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: {
        code: "23514",
        message: "INTERN Contant volledig ontvangen",
      },
    });

    const response = await POST(request(validBody));
    const text = await response.text();

    expect(response.status).toBe(409);
    expect(text).not.toContain("INTERN");
    expect(text).not.toContain(validBody.reason);
  });
});
