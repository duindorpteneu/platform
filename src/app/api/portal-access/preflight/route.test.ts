import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ preview: vi.fn() }));
vi.mock("@/server/portal-access/workspace", () => ({ previewPortalAccess: mocks.preview }));
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

const seasonId = "10000000-0000-4000-8000-000000000001";
const memberSeasonId = "20000000-0000-4000-8000-000000000001";
const staff = {
  userId: "30000000-0000-4000-8000-000000000001",
  displayName: "Beheerder",
  role: "beheerder" as const,
  activeSeason: { id: seasonId, name: "2026/27" },
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/portal-access/preflight", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/portal-access/preflight", () => {
  beforeEach(() => {
    mocks.preview.mockReset().mockResolvedValue({
      data: {
        operation: "activate",
        seasonId,
        seasonName: "2026/27",
        selectionCount: 1,
        eligibleCount: 1,
        unchangedCount: 0,
        blockedCount: 0,
        revision: "a".repeat(64),
        mailTemplate: {
          key: "portal_access_invite",
          version: 3,
          subjectSource: "Toegang tot {{clubnaam}}",
          bodySource: "Open zelf {{portaal_url}}. Vragen? {{contact_email}}",
          allowedShortcodes: [
            "{{clubnaam}}",
            "{{portaal_url}}",
            "{{contact_email}}",
          ],
          clubName: "Duindorp SV",
          contactEmail: "kleding@duindorpsv.nl",
        },
        groups: [{
          key: "b".repeat(64),
          email: "ouder@example.invalid",
          existingAccount: false,
          invitationRequired: true,
          nonSelectedCount: 0,
          status: "eligible",
          blockers: [],
          members: [{
            memberSeasonId,
            memberId: "40000000-0000-4000-8000-000000000001",
            relationNumber: "DSV-1",
            firstName: "Test",
            insertion: null,
            lastName: "Lid",
            team: "JO11-1",
            status: "eligible",
            activeGrantId: null,
          }],
        }],
      },
      staff,
      error: null,
    });
  });

  it("returns a short-lived token without readable member or e-mail identifiers", async () => {
    const response = await POST(request({
      operation: "activate",
      seasonId,
      memberSeasonIds: [memberSeasonId],
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    const payload = await response.json();
    expect(payload.previewToken).toEqual(expect.any(String));
    expect(payload.mailPreview).toEqual({
      subject: "Toegang tot Duindorp SV",
      text: "Open zelf https://tenue.example/login. Vragen? kleding@duindorpsv.nl",
      templateVersion: 3,
    });
    const decoded = Buffer.from(payload.previewToken.split(".")[0], "base64url").toString("utf8");
    expect(decoded).not.toContain(memberSeasonId);
    expect(decoded).not.toContain("ouder@example.invalid");
  });

  it("rejects duplicate identifiers before the database", async () => {
    const response = await POST(request({
      operation: "activate",
      seasonId,
      memberSeasonIds: [memberSeasonId, memberSeasonId],
    }));
    expect(response.status).toBe(400);
    expect(mocks.preview).not.toHaveBeenCalled();
  });
});
