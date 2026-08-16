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

const orderLineId = "10000000-0000-4000-8000-000000000001";
const orderId = "20000000-0000-4000-8000-000000000001";
const requestId = "30000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/orders/loose-lines/remove", {
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

describe("POST /api/orders/loose-lines/remove", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        requestId,
        orderId,
        orderLineId,
        status: "cancelled",
        reused: false,
      },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("annuleert alleen via de beheerder-RPC met reden en idempotentie", async () => {
    const response = await POST(request({
      orderLineId,
      reason: "Per ongeluk los toegevoegd",
      requestId,
    }));
    expect(response.status).toBe(200);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "remove_loose_order_line_v1",
      expect.objectContaining({
        p_order_line_id: orderLineId,
        p_reason: "Per ongeluk los toegevoegd",
        p_request_id: requestId,
      }),
    );
  });

  it("weigert een onvolledige reden voor autorisatie", async () => {
    const response = await POST(request({ orderLineId, reason: "x", requestId }));
    expect(response.status).toBe(400);
    expect(mocks.requireRole).not.toHaveBeenCalled();
  });

  it("vertaalt logistieke blokkades zonder database-informatie te lekken", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "sensitive database context" },
    });
    const response = await POST(request({
      orderLineId,
      reason: "Per ongeluk los toegevoegd",
      requestId,
    }));
    expect(response.status).toBe(409);
    expect(await response.text()).not.toContain("sensitive database context");
  });

  it("vereist beheerder-MFA", async () => {
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(request({
      orderLineId,
      reason: "Per ongeluk los toegevoegd",
      requestId,
    }));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
