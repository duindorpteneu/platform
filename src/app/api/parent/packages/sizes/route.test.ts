import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getParentSession: vi.fn(),
  getAdmin: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/parent-session", () => ({
  getParentSession: mocks.getParentSession,
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.getAdmin,
}));

import { POST } from "./route";

const memberSeasonId = "10000000-0000-4000-8000-000000000001";
const articleId = "20000000-0000-4000-8000-000000000001";
const variantId = "30000000-0000-4000-8000-000000000001";
const requestId = "40000000-0000-4000-8000-000000000001";
const orderId = "50000000-0000-4000-8000-000000000001";
const confirmationId = "60000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/parent/packages/sizes", {
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
  revision: "a".repeat(64),
  requestId,
  selections: [{
    articleId,
    kind: "variant",
    variantId,
    note: null,
  }],
};

describe("POST /api/parent/packages/sizes", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.getParentSession.mockReset().mockResolvedValue({
      tokenHash: "b".repeat(64),
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        memberSeasonId,
        orderId,
        confirmationId,
        selectedCount: 1,
        conflictCount: 0,
        changeRequestCount: 0,
        sizesConfirmed: true,
        revision: "c".repeat(64),
        reused: false,
      },
      error: null,
    });
    mocks.getAdmin.mockReset().mockReturnValue({ rpc: mocks.rpc });
  });

  it("bevestigt het volledige selectiecontract idempotent via één RPC", async () => {
    const response = await POST(request(validBody));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "confirm_parent_package_sizes_v5",
      expect.objectContaining({
        p_token_hash: "b".repeat(64),
        p_member_season_id: memberSeasonId,
        p_selections: validBody.selections,
        p_expected_revision: "a".repeat(64),
        p_request_id: requestId,
      }),
    );
  });

  it("weigert Anders zonder toelichting vóór databasegebruik", async () => {
    const response = await POST(request({
      ...validBody,
      selections: [{
        articleId,
        kind: "other",
        variantId: null,
        note: null,
      }],
    }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("weigert dubbele artikelen vóór databasegebruik", async () => {
    const response = await POST(request({
      ...validBody,
      selections: [...validBody.selections, ...validBody.selections],
    }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een idempotentieconflict zonder databasecontext te lekken", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: {
        code: "23505",
        message: "PACKAGE_SIZE_IDEMPOTENCY_CONFLICT interne rij",
      },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(409);
    expect(JSON.stringify(await response.json())).not.toContain("interne rij");
  });

  it("vereist een geldige oudersessie", async () => {
    mocks.getParentSession.mockResolvedValueOnce(null);
    const response = await POST(request(validBody));
    expect(response.status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
