import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ requireRole: vi.fn(), serverClient: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", () => ({ guardBrowserMutation: () => null }));
vi.mock("@/lib/env", () => ({ getServerEnv: () => ({ PARENT_TOKEN_PEPPER: "route-test-pepper-with-at-least-32-characters" }) }));

import { POST } from "./route";
import { createTeamPreviewToken } from "@/server/security/team-preview-token";

function request(body: unknown) {
  return new Request("https://tenue.example/api/members/team-status", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://tenue.example", Host: "tenue.example", "Sec-Fetch-Site": "same-origin", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

const response = { seasonId: "71000000-0000-4000-8000-000000000001", team: "JO11-1", totalMembers: 18, changedMembers: 17, unchangedMembers: 1, activeForSeason: false, committed: false, revision: "a".repeat(64) };

describe("POST /api/members/team-status", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: response, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("gebruikt voor de eerste stap uitsluitend de preview-RPC", async () => {
    const result = await POST(request({ team: "JO11-1", active: false, commit: false }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("preview_team_member_status_v2", { p_team: "JO11-1", p_active: false });
  });

  it("weigert commit zonder auditreden vóór de database", async () => {
    const result = await POST(request({ team: "JO11-1", active: false, commit: true }));
    expect(result.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("bindt commit aan de ondertekende preview-snapshot", async () => {
    const previewToken = createTeamPreviewToken({ operation: "member-status", team: "JO11-1", active: false, seasonId: response.seasonId, revision: response.revision }, "route-test-pepper-with-at-least-32-characters");
    const committed: Record<string, unknown> = { ...response }; delete committed.revision;
    mocks.rpc.mockResolvedValueOnce({ data: { ...committed, committed: true }, error: null });
    const result = await POST(request({ team: "JO11-1", active: false, reason: "Team afgemeld", previewToken, commit: true }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("bulk_set_team_member_status_v2", expect.objectContaining({ p_expected_season_id: response.seasonId, p_expected_revision: response.revision }));
  });
});
