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

const memberSeasonId = "10000000-0000-4000-8000-000000000001";
const packageRevisionId = "20000000-0000-4000-8000-000000000001";
const orderId = "30000000-0000-4000-8000-000000000001";
const requestId = "40000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/orders/package", {
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
  memberSeasonId,
  packageRevisionId,
  revision: "a".repeat(64),
  reason: "Pakket gekozen op verzoek van lid",
  requestId,
};

describe("POST /api/orders/package", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        memberSeasonId,
        orderId,
        packageRevisionId,
        changed: true,
        revision: "b".repeat(64),
        reused: false,
      },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("laat uitsluitend beheerder het server-side pakketcontract gebruiken", async () => {
    const response = await POST(request(validBody));
    expect(response.status).toBe(200);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "select_member_package_v3",
      expect.objectContaining({
        p_member_season_id: memberSeasonId,
        p_package_revision_id: packageRevisionId,
        p_expected_revision: "a".repeat(64),
        p_reason: validBody.reason,
        p_request_id: requestId,
      }),
    );
  });

  it("weigert een ontbrekende beheerreden vóór autorisatie", async () => {
    const response = await POST(request({ ...validBody, reason: "" }));
    expect(response.status).toBe(400);
    expect(mocks.requireRole).not.toHaveBeenCalled();
  });

  it("weigert een ontbrekende idempotency-id vóór autorisatie", async () => {
    const withoutRequestId = { ...validBody, requestId: undefined };
    const response = await POST(request(withoutRequestId));
    expect(response.status).toBe(400);
    expect(mocks.requireRole).not.toHaveBeenCalled();
  });

  it("laat de kledingcommissie de mutatie-RPC niet bereiken", async () => {
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );

    const response = await POST(request(validBody));

    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een stale pakketprojectie naar conflict", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "PACKAGE_SELECTION_CONFLICT" },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(409);
  });

  it("vertaalt hergebruik van een request-id met andere inhoud naar conflict", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23505", message: "gevoelige databasecontext" },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(409);
    expect(await response.text()).not.toContain("gevoelige databasecontext");
  });
});
