import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  requireSession: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffSessionBinding: mocks.requireSession,
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));

import { POST } from "./route";

const lineId = "10000000-0000-4000-8000-000000000001";
const requestId = "20000000-0000-4000-8000-000000000001";
const correlationId = "40000000-0000-4000-8000-000000000001";
const staff = {
  userId: "30000000-0000-4000-8000-000000000001",
  role: "beheerder",
  sessionTokenHash: "a".repeat(64),
};
const validBody = {
  orderLineIds: [lineId],
  targetStatus: "ready_for_pickup",
  reason: "Onjuiste tas meegegeven",
  requestId,
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/fulfilment/reverse", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": correlationId,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/fulfilment/reverse", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireSession.mockReset().mockResolvedValue(staff);
    mocks.rpc.mockReset().mockResolvedValue({
      data: { status: "corrected", correctedLines: 1, reused: false },
      error: null,
    });
    mocks.admin.mockReset().mockReturnValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("gebruikt een stabiele request-ID en sessiegebonden correctie-RPC", async () => {
    const response = await POST(request(validBody));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireSession).toHaveBeenCalledWith([
      "beheerder",
      "kledingcommissie",
    ]);
    expect(mocks.rpc).toHaveBeenCalledWith("correct_fulfilment_v3", {
      p_actor_id: staff.userId,
      p_correlation_id: correlationId,
      p_order_line_ids: [lineId],
      p_reason: validBody.reason,
      p_request_id: requestId,
      p_staff_session_hash: staff.sessionTokenHash,
      p_target_status: "ready_for_pickup",
    });
  });

  it("vertaalt races naar 409 en onbekende DB-fouten naar 503", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "sensitive" },
    });
    expect((await POST(request(validBody))).status).toBe(409);
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "XX000", message: "postgres://sensitive" },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("postgres");
  });

  it("weigert ontbrekende reden of request-ID vóór de database", async () => {
    const response = await POST(request({
      ...validBody,
      requestId: undefined,
      reason: "",
    }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("blokkeert een onbevoegde sessie vóór de database", async () => {
    mocks.requireSession.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(request(validBody));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
