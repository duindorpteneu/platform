import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ workspace: vi.fn() }));
vi.mock("@/server/action-items/workspace", () => ({
  getActionItemWorkspace: mocks.workspace,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const seasonId = "10000000-0000-4000-8000-000000000001";
const userId = "20000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/action-items/query", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/action-items/query", () => {
  beforeEach(() => {
    mocks.workspace.mockReset().mockResolvedValue({
      data: {
        tenantKey: "duindorp-sv",
        activeSeason: { id: seasonId, name: "2026/27" },
        selectedSeason: { id: seasonId, name: "2026/27", status: "open" },
        seasons: [{
          id: seasonId,
          name: "2026/27",
          status: "open",
          active: true,
        }],
        statusCounts: {
          open: 0,
          inProgress: 0,
          resolved: 0,
          dismissed: 0,
        },
        ownerOptions: [],
        viewer: { userId, role: "beheerder" },
        offset: 0,
        limit: 50,
        total: 0,
        items: [],
      },
      staff: { userId, role: "beheerder" },
      error: null,
    });
  });

  it("keeps filters in a no-store POST body", async () => {
    const body = {
      seasonId,
      status: "open",
      severity: "critical",
      ownerUserId: null,
      onlyUnassigned: true,
      offset: 0,
      limit: 50,
    };
    const response = await POST(request(body));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.workspace).toHaveBeenCalledWith(body);
  });

  it("rejects unknown or contradictory filters before the database", async () => {
    const response = await POST(request({
      seasonId,
      status: null,
      severity: null,
      ownerUserId: userId,
      onlyUnassigned: true,
      offset: 0,
      limit: 50,
      memberName: "niet toegestaan",
    }));

    expect(response.status).toBe(400);
    expect(mocks.workspace).not.toHaveBeenCalled();
  });
});
