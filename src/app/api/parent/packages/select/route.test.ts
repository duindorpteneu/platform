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
const packageRevisionId = "20000000-0000-4000-8000-000000000001";
const orderId = "30000000-0000-4000-8000-000000000001";
const requestId = "40000000-0000-4000-8000-000000000001";

function request(body: unknown, origin = "https://tenue.example") {
  return new Request("https://tenue.example/api/parent/packages/select", {
    method: "POST",
    headers: {
      origin,
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
  requestId,
};

describe("POST /api/parent/packages/select", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.getParentSession.mockReset().mockResolvedValue({
      tokenHash: "b".repeat(64),
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        memberSeasonId,
        orderId,
        packageRevisionId,
        changed: true,
        revision: "c".repeat(64),
        reused: false,
      },
      error: null,
    });
    mocks.getAdmin.mockReset().mockReturnValue({ rpc: mocks.rpc });
  });

  it("kiest alleen via de service-RPC en leidt prijs of inhoud niet uit de browser af", async () => {
    const response = await POST(request(validBody));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "select_parent_package_v3",
      expect.objectContaining({
        p_token_hash: "b".repeat(64),
        p_member_season_id: memberSeasonId,
        p_package_revision_id: packageRevisionId,
        p_expected_revision: "a".repeat(64),
        p_request_id: requestId,
      }),
    );
  });

  it("weigert onverwachte commerciële velden vóór databasegebruik", async () => {
    const response = await POST(request({ ...validBody, priceCents: 1 }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("weigert cross-site verzoeken al bij de mutatiegrens", async () => {
    const response = await POST(request(validBody, "https://aanvaller.example"));
    expect(response.status).toBe(403);
    expect(mocks.getParentSession).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een stale revision naar een herlaadbaar conflict", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "PACKAGE_SELECTION_CONFLICT" },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(409);
  });

  it("redigeert onverwachte databasefouten", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "XX000", message: "interne tabelgegevens" },
    });
    const response = await POST(request(validBody));
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("tabelgegevens");
  });
});
