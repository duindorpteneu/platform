import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ requireRole: vi.fn(), serverClient: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/route-guard", () => ({ guardBrowserMutation: () => null }));

import { POST } from "./route";

const memberId = "71000000-0000-4000-8000-000000000001";
const seasonId = "72000000-0000-4000-8000-000000000001";
const articleId = "73000000-0000-4000-8000-000000000001";
const variantId = "74000000-0000-4000-8000-000000000001";
const revision = "a".repeat(64);
const profile = {
  seasonId,
  seasonName: "2026/2027",
  editable: true,
  revision: "b".repeat(64),
  articles: [{ id: articleId, name: "Shirt", code: "SHIRT", active: true, selectedVariantId: variantId, ordered: false, orderLineStatus: null, variants: [{ id: variantId, size: "152", active: true }] }],
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/members/sizes", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://tenue.example", Host: "tenue.example", "Sec-Fetch-Site": "same-origin", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/members/sizes", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({});
    mocks.rpc.mockReset().mockResolvedValue({ data: profile, error: null });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("stuurt alleen een strikt, seizoensgebonden maatprofiel naar de RPC", async () => {
    const body = { memberId, seasonId, revision, sizes: [{ articleId, variantId }] };
    const response = await POST(request(body));
    expect(response.status).toBe(200);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder", "kledingcommissie"]);
    expect(mocks.rpc).toHaveBeenCalledWith("set_member_article_sizes", expect.objectContaining({ p_member_id: memberId, p_season_id: seasonId, p_sizes: body.sizes, p_expected_revision: revision }));
  });

  it("weigert dubbele artikelen vóór de database", async () => {
    const response = await POST(request({ memberId, seasonId, revision, sizes: [{ articleId, variantId }, { articleId, variantId: null }] }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een stale write naar een herlaadbaar conflict", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "40001" } });
    const response = await POST(request({ memberId, seasonId, revision, sizes: [{ articleId, variantId }] }));
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: expect.stringContaining("intussen gewijzigd") });
  });
});
