import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  revoke: vi.fn(),
  staff: vi.fn(),
}));
vi.mock("@/server/portal-access/workspace", () => ({ revokePortalAccess: mocks.revoke }));
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
const grantId = "30000000-0000-4000-8000-000000000001";
const batchKey = "40000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/portal-access/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/portal-access/revoke", () => {
  beforeEach(() => {
    mocks.staff.mockReset().mockResolvedValue({
      userId: actorId,
      displayName: "Beheerder",
      role: "beheerder",
      activeSeason: { id: seasonId, name: "2026/27" },
    });
    mocks.revoke.mockReset().mockResolvedValue({
      data: {
        operation: "revoke",
        seasonId,
        selectedCount: 1,
        changedCount: 1,
        unchangedCount: 0,
        groupCount: 1,
        inviteJobCount: 0,
        sessionsRevoked: 1,
        committed: true,
        reused: false,
      },
      error: null,
    });
  });

  it("requires a reason and forwards the signed revision", async () => {
    const token = createPortalAccessPreviewToken({
      operation: "revoke",
      actorId,
      seasonId,
      ids: [grantId],
      revision: "b".repeat(64),
    }, pepper);
    const response = await POST(request({
      seasonId,
      grantIds: [grantId],
      reason: "Toegang op verzoek ingetrokken",
      previewToken: token,
      batchKey,
    }));
    expect(response.status).toBe(200);
    expect(mocks.revoke).toHaveBeenCalledWith(expect.objectContaining({
      grantIds: [grantId],
      reason: "Toegang op verzoek ingetrokken",
      expectedRevision: "b".repeat(64),
    }));
  });

  it("rejects a blank reason before authorization or mutation", async () => {
    const response = await POST(request({
      seasonId,
      grantIds: [grantId],
      reason: " ",
      previewToken: "x".repeat(64),
      batchKey,
    }));
    expect(response.status).toBe(400);
    expect(mocks.staff).not.toHaveBeenCalled();
    expect(mocks.revoke).not.toHaveBeenCalled();
  });
});
