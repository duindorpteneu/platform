import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ requireRole: vi.fn(), serverClient: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", () => ({ guardBrowserMutation: () => null }));

import { POST } from "./route";

const variantId = "72000000-0000-4000-8000-000000000001";
function request(body: unknown) {
  return new Request("https://tenue.example/api/orders/team-articles", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://tenue.example", Host: "tenue.example", "Sec-Fetch-Site": "same-origin", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

const response = { seasonId: "71000000-0000-4000-8000-000000000001", team: "JO11-1", selectedVariantCount: 1, totalMembers: 18, activeMembers: 17, inactiveMembersSkipped: 1, paidOrdersSkipped: 2, ordersCreated: 4, ordersExtended: 10, unchangedMembers: 1, linesAdded: 14, committed: false };

describe("POST /api/orders/team-articles", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: response, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("gebruikt een server-side preview voor teamtoewijzing", async () => {
    const result = await POST(request({ team: "JO11-1", variantIds: [variantId], commit: false }));
    expect(result.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("preview_team_order_articles", { p_team: "JO11-1", p_variant_ids: [variantId] });
  });

  it("weigert dubbele varianten vóór de database", async () => {
    const result = await POST(request({ team: "JO11-1", variantIds: [variantId, variantId], commit: true }));
    expect(result.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
