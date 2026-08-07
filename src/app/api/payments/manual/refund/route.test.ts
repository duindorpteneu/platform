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

const ids = {
  order: "10000000-0000-4000-8000-000000000001",
  payment: "20000000-0000-4000-8000-000000000001",
  request: "30000000-0000-4000-8000-000000000001",
  memberSeason: "40000000-0000-4000-8000-000000000001",
  season: "50000000-0000-4000-8000-000000000001",
  snapshot: "60000000-0000-4000-8000-000000000001",
} as const;

const body = {
  orderId: ids.order,
  paymentId: ids.payment,
  amountCents: 12_500,
  reason: "Contante betaling aantoonbaar teruggegeven",
  evidenceReference: "Kasbon 2026-081",
  requestId: ids.request,
} as const;

function request(candidate: unknown) {
  return new Request("https://tenue.example/api/payments/manual/refund", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(candidate),
  });
}

describe("POST /api/payments/manual/refund", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        requestId: ids.request,
        paymentId: ids.payment,
        orderId: ids.order,
        memberSeasonId: ids.memberSeason,
        seasonId: ids.season,
        packageSnapshotId: ids.snapshot,
        status: "refunded",
        method: "cash",
        amountCents: 12_500,
        currency: "EUR",
        refundedAt: "2026-08-03T10:00:00.000Z",
        releasedAllocationCount: 1,
        qrRevoked: true,
        refundCreated: false,
        refundExternallyConfirmed: true,
        reused: false,
      },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("roept uitsluitend het beheerder/AAL2-refundcontract aan", async () => {
    const response = await POST(request(body));

    expect(response.status).toBe(200);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "record_manual_payment_refund_v1",
      {
        p_order_id: ids.order,
        p_payment_id: ids.payment,
        p_amount_cents: 12_500,
        p_reason: body.reason,
        p_evidence_reference: body.evidenceReference,
        p_request_id: ids.request,
      },
    );
  });

  it("weigert kledingcommissie vóór de RPC", async () => {
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );

    const response = await POST(request(body));

    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vereist bewijsreferentie en lekt databasecontext niet", async () => {
    const invalid = await POST(request({ ...body, evidenceReference: "" }));
    expect(invalid.status).toBe(400);

    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: `INTERN ${body.reason}` },
    });
    const conflict = await POST(request(body));
    const text = await conflict.text();
    expect(conflict.status).toBe(409);
    expect(text).not.toContain(body.reason);
    expect(text).not.toContain("INTERN");
  });
});
