import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const memberId = "71000000-0000-4000-8000-000000000001";
const memberSeasonId = "72000000-0000-4000-8000-000000000001";
const preview = {
  portalAccessActive: true,
  transferRequired: true,
  currentMemberEmail: "oud@example.invalid",
  currentPortalEmail: "oud@example.invalid",
  newEmail: "nieuw@example.invalid",
  affectedMemberCount: 2,
  affectedMemberSeasonCount: 2,
  activePortalCount: 2,
  targetAccountReused: false,
  blockedCount: 0,
  affectedChildren: [{
    memberId,
    memberSeasonId,
    memberName: "Noor Tester",
    team: "MO11-1",
  }],
  familyRevision: "b".repeat(64),
};

function request(overrides: Record<string, unknown> = {}) {
  return new Request("https://tenue.example/api/members/profile/email-preflight", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: "https://tenue.example",
      Host: "tenue.example",
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify({
      memberId,
      memberSeasonId,
      email: "nieuw@example.invalid",
      revision: "a".repeat(64),
      ...overrides,
    }),
  });
}

describe("POST /api/members/profile/email-preflight", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: preview, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("vereist beheerder en haalt de autoritatieve familie op", async () => {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "preview_member_family_email_transfer_v1",
      expect.objectContaining({
        p_member_id: memberId,
        p_member_season_id: memberSeasonId,
        p_new_email: "nieuw@example.invalid",
      }),
    );
  });

  it("weigert conflicterende portaldata", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { ...preview, blockedCount: 1 },
      error: null,
    });
    const response = await POST(request());
    expect(response.status).toBe(409);
  });

  it("vertaalt een verlopen revision naar een hercontrole", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "40001" } });
    const response = await POST(request());
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: expect.stringContaining("intussen") });
  });
});
