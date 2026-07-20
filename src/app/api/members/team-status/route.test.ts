import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ requireRole: vi.fn(), serverClient: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", () => ({ guardBrowserMutation: () => null }));

import { POST } from "./route";

function request(body: unknown) {
  return new Request("https://tenue.example/api/members/team-status", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://tenue.example", Host: "tenue.example", "Sec-Fetch-Site": "same-origin", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

const response = { seasonId: "71000000-0000-4000-8000-000000000001", team: "JO11-1", totalMembers: 18, changedMembers: 17, unchangedMembers: 1, activeForSeason: false, committed: false };

describe("POST /api/members/team-status", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: response, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("gebruikt voor de eerste stap uitsluitend de preview-RPC", async () => {
    const result = await POST(request({ team: "JO11-1", active: false, commit: false }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("preview_team_member_status", { p_team: "JO11-1", p_active: false });
  });

  it("weigert commit zonder auditreden vóór de database", async () => {
    const result = await POST(request({ team: "JO11-1", active: false, commit: true }));
    expect(result.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
