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

const requestId = "10000000-0000-4000-8000-000000000001";
const memberSeasonId = "20000000-0000-4000-8000-000000000001";
const oldLineId = "30000000-0000-4000-8000-000000000001";
const newLineId = "40000000-0000-4000-8000-000000000001";
const variantId = "50000000-0000-4000-8000-000000000001";
const reservationId = "60000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request(
    "https://tenue.example/api/orders/package-size-change",
    {
      method: "POST",
      headers: {
        origin: "https://tenue.example",
        host: "tenue.example",
        "sec-fetch-site": "same-origin",
        "x-duindorp-csrf": "same-origin",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
}

const validBody = {
  requestId,
  decision: "approve",
  approvedVariantId: variantId,
  reason: "Geldige maat handmatig gekoppeld",
  revision: "a".repeat(64),
};

describe("POST /api/orders/package-size-change", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        requestId,
        memberSeasonId,
        orderLineId: newLineId,
        replacedOrderLineId: oldLineId,
        status: "approved",
        releasedReservationId: reservationId,
        revision: "b".repeat(64),
        reused: false,
      },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("vereist beheerder en een concrete goedgekeurde variant", async () => {
    const response = await POST(request(validBody));
    expect(response.status).toBe(200);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "resolve_package_size_change_v3",
      expect.objectContaining({
        p_request_id: requestId,
        p_decision: "approve",
        p_approved_variant_id: variantId,
        p_reason: validBody.reason,
      }),
    );
  });

  it("weigert goedkeuring zonder echte variant vóór autorisatie", async () => {
    const response = await POST(request({
      ...validBody,
      approvedVariantId: null,
    }));
    expect(response.status).toBe(400);
    expect(mocks.requireRole).not.toHaveBeenCalled();
  });

  it("laat de kledingcommissie de beslis-RPC niet bereiken", async () => {
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );

    const response = await POST(request(validBody));

    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("staat afwijzing uitsluitend zonder vervangende variant toe", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        requestId,
        memberSeasonId,
        orderLineId: oldLineId,
        status: "rejected",
        releasedReservationId: null,
        revision: "b".repeat(64),
        reused: false,
      },
      error: null,
    });
    const response = await POST(request({
      ...validBody,
      decision: "reject",
      approvedVariantId: null,
    }));
    expect(response.status).toBe(200);
  });

  it("vertaalt een gelijktijdige beslissing naar conflict", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "interne toestand" },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(409);
    expect(JSON.stringify(await response.json())).not.toContain(
      "interne toestand",
    );
  });
});
