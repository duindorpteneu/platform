import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

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

const requestId = "10000000-0000-4000-8000-000000000001";
const lineId = "30000000-0000-4000-8000-000000000001";
const correlationId = "40000000-0000-4000-8000-000000000001";
const scanGrant = `sg2.k1.${"a".repeat(43)}`;
const staff = {
  userId: "20000000-0000-4000-8000-000000000001",
  role: "uitgifte",
  sessionTokenHash: "b".repeat(64),
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/fulfilment/commit", {
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

describe("POST /api/fulfilment/commit", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.QR_TOKEN_PEPPER =
      Buffer.alloc(32, 4).toString("base64url");
    process.env.QR_TOKEN_PEPPER_VERSION = "1";
    mocks.requireSession.mockReset().mockResolvedValue(staff);
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        status: "completed",
        issuedLines: 1,
        completedAt: "2026-08-03T10:00:00.000Z",
        outcome: "partial_pickup",
        reused: false,
      },
      error: null,
    });
    mocks.admin.mockReset().mockReturnValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  afterEach(() => {
    delete process.env.APP_BASE_URL;
    delete process.env.QR_TOKEN_PEPPER;
    delete process.env.QR_TOKEN_PEPPER_VERSION;
  });

  it("commit één geselecteerde set met een single-use sessiegrant", async () => {
    const response = await POST(request({
      orderLineIds: [lineId],
      requestId,
      scanGrant,
    }));
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledWith("commit_fulfilment_v3", {
      p_actor_id: staff.userId,
      p_correlation_id: correlationId,
      p_grant_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
      p_order_line_ids: [lineId],
      p_request_id: requestId,
      p_staff_session_hash: staff.sessionTokenHash,
    });
  });

  it("weigert dubbele regels vóór de database", async () => {
    const response = await POST(request({
      orderLineIds: [lineId, lineId],
      requestId,
      scanGrant,
    }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("behandelt een grant van een ingetrokken sleutelversie als verlopen", async () => {
    const response = await POST(request({
      orderLineIds: [lineId],
      requestId,
      scanGrant: `sg2.k9.${"a".repeat(43)}`,
    }));
    expect(response.status).toBe(409);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it.each(["stale", "blocked"] as const)(
    "laat de scanner bij %s opnieuw scannen",
    async (status) => {
      mocks.rpc.mockResolvedValueOnce({ data: { status }, error: null });
      const response = await POST(request({
        orderLineIds: [lineId],
        requestId,
        scanGrant,
      }));
      expect(response.status).toBe(409);
      expect(await response.text()).not.toContain(scanGrant);
    },
  );

  it("onderscheidt een domeinconflict van een databasefout", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "sensitive" },
    });
    expect((await POST(request({
      orderLineIds: [lineId],
      requestId,
      scanGrant,
    }))).status).toBe(409);
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "XX000", message: "postgres://sensitive" },
    });
    const response = await POST(request({
      orderLineIds: [lineId],
      requestId,
      scanGrant,
    }));
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("postgres");
  });

  it("blokkeert een niet-bevoegde sessie vóór de RPC", async () => {
    mocks.requireSession.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(request({
      orderLineIds: [lineId],
      requestId,
      scanGrant,
    }));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("faalt gesloten op een ongeldig succesantwoord", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { status: "completed", issuedLines: 0 },
      error: null,
    });
    const response = await POST(request({
      orderLineIds: [lineId],
      requestId,
      scanGrant,
    }));
    expect(response.status).toBe(502);
  });
});
