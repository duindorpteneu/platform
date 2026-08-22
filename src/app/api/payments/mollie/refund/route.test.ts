import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireSession: vi.fn(),
  admin: vi.fn(),
  startRefund: vi.fn(),
  trustedOrigin: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({
  requireStaffSessionBinding: mocks.requireSession,
}));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/payments/mollie-service", async (load) => {
  const actual = await load<typeof import("@/server/payments/mollie-service")>();
  return {
    ...actual,
    getMollieRuntimeConfig: () => ({ enabled: true, apiKey: "test_000000000000", appBaseUrl: "https://tenue.example" }),
    hasTrustedPaymentOrigin: mocks.trustedOrigin,
    startMollieRefund: mocks.startRefund,
  };
});

import { POST } from "./route";

const refundId = "10000000-0000-4000-8000-000000000001";
const staff = {
  userId: "20000000-0000-4000-8000-000000000001",
  role: "beheerder",
  sessionTokenHash: "a".repeat(64),
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/payments/mollie/refund", {
    method: "POST",
    headers: {
      origin: "https://tenue.example", host: "tenue.example",
      "sec-fetch-site": "same-origin", "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/payments/mollie/refund", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireSession.mockReset().mockResolvedValue(staff);
    mocks.admin.mockReset().mockReturnValue({ schema: vi.fn() });
    mocks.trustedOrigin.mockReset().mockReturnValue(true);
    mocks.startRefund.mockReset().mockResolvedValue({
      refundId, providerRefundId: "re_test123", status: "pending", reused: false,
    });
  });

  it("vereist MFA-beheer en start alleen de bestaande refundverplichting", async () => {
    const response = await POST(request({ refundId, requestId: refundId }));
    expect(response.status).toBe(200);
    expect(mocks.requireSession).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.startRefund).toHaveBeenCalledWith(
      expect.objectContaining({
        refundId,
        requestId: refundId,
        actorUserId: staff.userId,
        staffSessionHash: staff.sessionTokenHash,
      }),
      expect.objectContaining({ database: expect.any(Object) }),
    );
  });

  it("weigert een browserbedrag zodat alleen de ledger het bedrag bepaalt", async () => {
    const response = await POST(request({ refundId, requestId: refundId, amountCents: 1 }));
    expect(response.status).toBe(400);
    expect(mocks.startRefund).not.toHaveBeenCalled();
  });
});
