import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));

import { POST } from "./route";

const memberSeasonId = "aa000000-0000-4000-8000-000000000001";
const packageRevisionId = "ab000000-0000-4000-8000-000000000001";
const seasonId = "ac000000-0000-4000-8000-000000000001";
const requestId = "ad000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/orders/member-packages", {
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

const base = {
  action: "assign" as const,
  scope: "selected" as const,
  memberSeasonIds: [memberSeasonId],
  packageRevisionId,
  reason: "Pakket toewijzen aan geselecteerd lid",
  requestId,
  commit: false,
};

const previewData = {
  action: "assign",
  scope: "selected",
  seasonId,
  packageRevisionId,
  requestedCount: 1,
  matchedCount: 1,
  eligibleCount: 1,
  unchangedCount: 0,
  blockedCount: 0,
  inactiveOrInvalidCount: 0,
  linkedSizeCount: 2,
  missingSizeCount: 0,
  revision: "a".repeat(64),
};

describe("POST /api/orders/member-packages", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.PARENT_TOKEN_PEPPER = "route-test-parent-token-pepper-with-more-than-32-characters";
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({ data: previewData, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("maakt een beheerder-only voorcontrole en verbergt de databasehash in een getekend token", async () => {
    const response = await POST(request(base));
    const payload = await response.json();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith("preview_member_package_bulk_v1", expect.objectContaining({
      p_member_season_ids: [memberSeasonId],
      p_package_revision_id: packageRevisionId,
    }));
    expect(payload.previewToken).toEqual(expect.any(String));
    expect(payload.revision).toBeUndefined();
  });

  it("voert exact dezelfde getekende selectie uit", async () => {
    const previewResponse = await POST(request(base));
    const preview = await previewResponse.json();
    const committedData = Object.fromEntries(
      Object.entries(previewData).filter(([key]) => key !== "revision"),
    );
    mocks.rpc.mockResolvedValueOnce({
      data: {
        ...committedData,
        committed: true,
        changedCount: 1,
        reused: false,
      },
      error: null,
    });
    const response = await POST(request({ ...base, commit: true, previewToken: preview.previewToken }));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenLastCalledWith("apply_member_package_bulk_v1", expect.objectContaining({
      p_expected_season_id: seasonId,
      p_expected_revision: "a".repeat(64),
      p_reason: base.reason,
      p_request_id: requestId,
    }));
  });

  it("weigert een gewijzigde reden na de voorcontrole", async () => {
    const previewResponse = await POST(request(base));
    const preview = await previewResponse.json();
    const response = await POST(request({ ...base, reason: "Andere reden", commit: true, previewToken: preview.previewToken }));
    expect(response.status).toBe(409);
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
  });

  it("laat de kledingcommissie de RPC niet bereiken", async () => {
    mocks.requireRole.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    const response = await POST(request(base));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een stale preflight zonder databasecontext te lekken", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "40001", message: "gevoelige databasecontext" } });
    const response = await POST(request(base));
    expect(response.status).toBe(409);
    expect(await response.text()).not.toContain("gevoelige databasecontext");
  });
});
