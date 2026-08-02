import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  activate: vi.fn(),
  staff: vi.fn(),
}));
vi.mock("@/server/portal-access/workspace", () => ({ activatePortalAccess: mocks.activate }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.staff }));
vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({
    PARENT_TOKEN_PEPPER: "portal-access-route-test-pepper-32-characters",
    APP_BASE_URL: "https://tenue.example",
  }),
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";
import { createPortalAccessPreviewToken } from "@/server/security/portal-access-preview-token";

const pepper = "portal-access-route-test-pepper-32-characters";
const actorId = "10000000-0000-4000-8000-000000000001";
const seasonId = "20000000-0000-4000-8000-000000000001";
const memberSeasonId = "30000000-0000-4000-8000-000000000001";
const batchKey = "40000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/portal-access/activate", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/portal-access/activate", () => {
  beforeEach(() => {
    mocks.staff.mockReset().mockResolvedValue({
      userId: actorId,
      displayName: "Beheerder",
      role: "beheerder",
      activeSeason: { id: seasonId, name: "2026/27" },
    });
    mocks.activate.mockReset().mockResolvedValue({
      data: {
        operation: "activate",
        seasonId,
        selectedCount: 1,
        changedCount: 1,
        unchangedCount: 0,
        groupCount: 1,
        inviteJobCount: 1,
        sessionsRevoked: 0,
        committed: true,
        reused: false,
      },
      error: null,
    });
  });

  it("binds the commit to actor, exact selection and database revision", async () => {
    const token = createPortalAccessPreviewToken({
      operation: "activate",
      actorId,
      seasonId,
      ids: [memberSeasonId],
      revision: "a".repeat(64),
    }, pepper);
    const response = await POST(request({
      seasonId,
      memberSeasonIds: [memberSeasonId],
      previewToken: token,
      batchKey,
    }));
    expect(response.status).toBe(200);
    expect(mocks.activate).toHaveBeenCalledWith(expect.objectContaining({
      seasonId,
      memberSeasonIds: [memberSeasonId],
      expectedRevision: "a".repeat(64),
      batchKey,
    }));
  });

  it("rejects a changed selection before any mutation", async () => {
    const token = createPortalAccessPreviewToken({
      operation: "activate",
      actorId,
      seasonId,
      ids: [memberSeasonId],
      revision: "a".repeat(64),
    }, pepper);
    const response = await POST(request({
      seasonId,
      memberSeasonIds: ["30000000-0000-4000-8000-000000000002"],
      previewToken: token,
      batchKey,
    }));
    expect(response.status).toBe(409);
    expect(mocks.activate).not.toHaveBeenCalled();
  });
});
