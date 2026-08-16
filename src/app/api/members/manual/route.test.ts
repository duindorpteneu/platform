import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireStaffRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));

import { POST } from "./route";

const seasonId = "10000000-0000-4000-8000-000000000001";
const memberId = "20000000-0000-4000-8000-000000000001";
const memberSeasonId = "30000000-0000-4000-8000-000000000001";
const clientRequestId = "40000000-0000-4000-8000-000000000001";
const fingerprint = "a".repeat(64);

function request(overrides: Record<string, unknown> = {}) {
  return new Request("https://tenue.example/api/members/manual", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      firstName: "Noa",
      lastName: "Jansen",
      dateOfBirth: "2014-01-31",
      gender: "female",
      clientRequestId,
      allowPotentialDuplicate: false,
      expectedFingerprint: null,
      ...overrides,
    }),
  });
}

describe("POST /api/members/manual", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireStaffRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset();
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("maakt na lege dubbeleledencontrole alleen het lid aan", async () => {
    mocks.rpc
      .mockResolvedValueOnce({
        data: { seasonId, seasonName: "2026/2027", candidates: [], fingerprint },
        error: null,
      })
      .mockResolvedValueOnce({
        data: { memberId, memberSeasonId, reused: false },
        error: null,
      });
    const response = await POST(request({ team: "JO14-1" }));
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ memberId, memberSeasonId, reused: false });
    expect(mocks.rpc).toHaveBeenNthCalledWith(2, "create_manual_member", expect.objectContaining({
      p_team: "JO14-1",
      p_expected_fingerprint: fingerprint,
      p_allow_potential_duplicate: false,
    }));
  });

  it("toont mogelijke dubbelen en schrijft nog niets", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        seasonId,
        seasonName: "2026/2027",
        fingerprint,
        candidates: [{
          memberId,
          memberName: "Noa Jansen",
          team: null,
          reasons: ["name_date_of_birth"],
        }],
      },
      error: null,
    });
    const response = await POST(request());
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ requiresConfirmation: true });
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
  });

  it("maakt een mogelijke dubbel alleen na bevestiging met dezelfde preflight", async () => {
    const preflight = {
      seasonId,
      seasonName: "2026/2027",
      fingerprint,
      candidates: [{
        memberId,
        memberName: "Noa Jansen",
        team: "JO14-1",
        reasons: ["name_email"],
      }],
    };
    mocks.rpc
      .mockResolvedValueOnce({ data: preflight, error: null })
      .mockResolvedValueOnce({ data: { memberId, memberSeasonId, reused: false }, error: null });
    const response = await POST(request({
      email: "ouder@example.test",
      allowPotentialDuplicate: true,
      expectedFingerprint: fingerprint,
    }));
    expect(response.status).toBe(201);
    expect(mocks.rpc).toHaveBeenNthCalledWith(2, "create_manual_member", expect.objectContaining({
      p_allow_potential_duplicate: true,
    }));
  });

  it("blokkeert een bestaand Sportlink-relatienummer altijd", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        seasonId,
        seasonName: "2026/2027",
        fingerprint,
        candidates: [{
          memberId,
          memberName: "Noa Jansen",
          team: null,
          reasons: ["external_id"],
        }],
      },
      error: null,
    });
    const response = await POST(request({ externalId: "SL-1" }));
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ hardConflict: true });
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
  });
});
