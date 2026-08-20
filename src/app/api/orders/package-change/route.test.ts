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
const targetId = "20000000-0000-4000-8000-000000000001";
const requestId = "30000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request(
    "https://tenue.example/api/orders/package-change",
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

const response = {
  requestId,
  orderId,
  memberSeasonId: "40000000-0000-4000-8000-000000000001",
  fromSnapshotId: "50000000-0000-4000-8000-000000000001",
  fromPackageRevisionId: targetId,
  fromPackageName: "Speler",
  fromPriceCents: 10000,
  fromCurrency: "EUR",
  toPackageRevisionId: "60000000-0000-4000-8000-000000000001",
  toPackageName: "Keeper",
  toPriceCents: 12500,
  toCurrency: "EUR",
  priceDeltaCents: 2500,
  effectivePaidCents: 10000,
  creditAvailableCents: 10000,
  creditAppliedCents: 10000,
  additionalDueCents: 2500,
  refundDueCents: 0,
  paymentMethod: "mollie",
  paymentSources: [{ paymentId: "70000000-0000-4000-8000-000000000001", method: "mollie", amountCents: 10000, paidAt: "2026-08-20T12:00:00Z" }],
  unresolvedPaymentCount: 1,
  reservedAllocationCount: 0,
  fulfilledAllocationCount: 0,
  requiresAllocationRelease: false,
  blockedByFulfilment: false,
  blockedByReconciliation: false,
  targetPackageRequiredSizeCount: 2,
  targetPackageKnownSizeCount: 1,
  targetPackageMissingSizeCount: 1,
  canApply: false,
  status: "blocked",
  revision: "a".repeat(64),
  reused: false,
  result: null,
};

describe("POST /api/orders/package-change", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireRole.mockReset().mockResolvedValue({
      role: "beheerder",
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: response,
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("preflights without changing payment or package", async () => {
    const result = await POST(request({
      action: "preflight",
      orderId,
      targetPackageRevisionId: targetId,
      reason: "Keeper geworden",
      requestId,
    }));
    expect(result.status).toBe(200);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "preflight_package_change_v2",
      expect.objectContaining({
        p_order_id: orderId,
        p_target_revision_id: targetId,
        p_request_id: requestId,
      }),
    );
  });

  it("applies only with the exact explicit confirmation", async () => {
    const result = await POST(request({
      action: "apply",
      requestId,
      revision: "a".repeat(64),
      confirmation: "SWITCH_PACKAGE",
    }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "apply_package_change_v2",
      expect.objectContaining({
        p_confirmation: "SWITCH_PACKAGE",
      }),
    );
  });

  it("rejects an automatic refund instruction before authorization", async () => {
    const result = await POST(request({
      action: "apply",
      requestId,
      revision: "a".repeat(64),
      confirmation: "REFUND_AND_SWITCH",
    }));
    expect(result.status).toBe(400);
    expect(mocks.requireRole).not.toHaveBeenCalled();
  });

  it("maps financial or fulfilment blockers without leaking SQL", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "sensitive context" },
    });
    const result = await POST(request({
      action: "preflight",
      orderId,
      targetPackageRevisionId: targetId,
      reason: "Keeper geworden",
      requestId,
    }));
    expect(result.status).toBe(409);
    expect(await result.text()).not.toContain("sensitive context");
  });
});
