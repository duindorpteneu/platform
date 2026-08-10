import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ requireRole: vi.fn(), serverClient: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));
vi.mock("@/lib/env", () => ({ getServerEnv: () => ({ PARENT_TOKEN_PEPPER: "route-test-pepper-with-at-least-32-characters" }) }));

import { POST } from "./route";
import { createTeamPreviewToken } from "@/server/security/team-preview-token";

const variantId = "72000000-0000-4000-8000-000000000001";
function request(body: unknown) {
  return new Request("https://tenue.example/api/orders/team-articles", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://tenue.example", Host: "tenue.example", "Sec-Fetch-Site": "same-origin", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

const response = { seasonId: "71000000-0000-4000-8000-000000000001", team: "JO11-1", selectedVariantCount: 1, totalMembers: 18, activeMembers: 17, inactiveMembersSkipped: 1, paidOrdersSkipped: 2, ordersCreated: 4, ordersExtended: 10, unchangedMembers: 1, linesAdded: 14, committed: false, revision: "b".repeat(64) };

describe("POST /api/orders/team-articles", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: response, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("gebruikt een server-side preview voor teamtoewijzing", async () => {
    const result = await POST(request({ team: "JO11-1", variantIds: [variantId], commit: false }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("preview_team_order_articles_v2", { p_team: "JO11-1", p_variant_ids: [variantId] });
  });

  it("weigert dubbele varianten vóór de database", async () => {
    const result = await POST(request({ team: "JO11-1", variantIds: [variantId, variantId], commit: true }));
    expect(result.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("bindt commit aan team, varianten, seizoen en snapshot", async () => {
    const previewToken = createTeamPreviewToken({ operation: "order-articles", team: "JO11-1", variantIds: [variantId], seasonId: response.seasonId, revision: response.revision }, "route-test-pepper-with-at-least-32-characters");
    const committed: Record<string, unknown> = { ...response }; delete committed.revision;
    mocks.rpc.mockResolvedValueOnce({ data: { ...committed, committed: true }, error: null });
    const result = await POST(request({ team: "JO11-1", variantIds: [variantId], previewToken, commit: true }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("bulk_add_team_order_articles_v2", expect.objectContaining({ p_expected_season_id: response.seasonId, p_expected_revision: response.revision }));
  });
});
