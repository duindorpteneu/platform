import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ requireRole: vi.fn(), serverClient: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const memberId = "71000000-0000-4000-8000-000000000001";
const memberSeasonId = "72000000-0000-4000-8000-000000000001";
const requestId = "73000000-0000-4000-8000-000000000001";
const profile = {
  id: memberId,
  memberSeasonId,
  profileRevision: "b".repeat(64),
  memberName: "Noor van Dijk",
  firstName: "Noor",
  insertion: "van",
  lastName: "Dijk",
  relationNumber: "12345",
  email: "ouder@example.invalid",
  team: "O13-1",
  activeForSeason: true,
  gender: "female",
  dateOfBirth: "2014-02-03",
  updatedAt: "2026-08-16T10:00:00.000Z",
  activeSeason: { id: "74000000-0000-4000-8000-000000000001", name: "2026/2027" },
  memberSeasons: [],
  sizeProfile: null,
  parentLinks: [],
  order: null,
  activities: [],
  reused: false,
  familyEmailTransfer: {
    portalAccessActive: false,
    accessTransferred: false,
    affectedMemberCount: 1,
    affectedMemberSeasonCount: 1,
    targetAccountReused: false,
    sessionsRevoked: 0,
    otpChallengesInvalidated: 0,
    oldAuthorizedMemberSeasonCount: 0,
    activationMailQueued: false,
  },
};

function request(overrides: Record<string, unknown> = {}) {
  return new Request("https://tenue.example/api/members/profile", {
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
      firstName: "Noor",
      insertion: "van",
      lastName: "Dijk",
      email: "ouder@example.invalid",
      dateOfBirth: "2014-02-03",
      gender: "female",
      team: "O13-1",
      revision: "a".repeat(64),
      reason: "Correctie op verzoek",
      requestId,
      ...overrides,
    }),
  });
}

describe("POST /api/members/profile", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: profile, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("vereist beheerder en stuurt alle velden naar de geaudite RPC", async () => {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith("update_member_profile_v2", expect.objectContaining({
      p_member_id: memberId,
      p_member_season_id: memberSeasonId,
      p_date_of_birth: "2014-02-03",
      p_request_id: requestId,
      p_expected_family_revision: null,
    }));
  });

  it("bindt een bevestigde gezinsrevision aan dezelfde profielmutatie", async () => {
    const familyRevision = "c".repeat(64);
    const response = await POST(request({ familyRevision }));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("update_member_profile_v2", expect.objectContaining({
      p_expected_family_revision: familyRevision,
    }));
  });

  it("weigert ongeldige profielvelden vóór de database", async () => {
    const response = await POST(request({ dateOfBirth: "2999-01-01" }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een gelijktijdige wijziging naar conflict", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "40001" } });
    const response = await POST(request());
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: expect.stringContaining("intussen gewijzigd") });
  });
});
