import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ workspace: vi.fn() }));
vi.mock("@/server/portal-access/workspace", () => ({
  getPortalAccessWorkspace: mocks.workspace,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const seasonId = "10000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/portal-access/query", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/portal-access/query", () => {
  beforeEach(() => {
    mocks.workspace.mockReset().mockResolvedValue({
      data: {
        activeSeason: { id: seasonId, name: "2026/27" },
        selectedSeason: { id: seasonId, name: "2026/27", status: "open" },
        seasons: [{
          id: seasonId,
          name: "2026/27",
          status: "open",
          active: true,
        }],
        offset: 0,
        limit: 50,
        total: 0,
        members: [],
      },
      staff: {
        userId: "20000000-0000-4000-8000-000000000001",
        displayName: "Beheerder",
        role: "beheerder",
        activeSeason: { id: seasonId, name: "2026/27" },
      },
      error: null,
    });
  });

  it("keeps member searches out of the URL and disables response caching", async () => {
    const response = await POST(request({
      seasonId,
      search: "ouder@example.invalid",
      offset: 0,
      limit: 50,
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store, private");
    expect(mocks.workspace).toHaveBeenCalledWith({
      seasonId,
      search: "ouder@example.invalid",
      offset: 0,
      limit: 50,
    });
  });

  it("rejects unknown fields before querying the database", async () => {
    const response = await POST(request({
      seasonId,
      search: null,
      offset: 0,
      limit: 50,
      dateOfBirth: "2013-03-04",
    }));

    expect(response.status).toBe(400);
    expect(mocks.workspace).not.toHaveBeenCalled();
  });
});
