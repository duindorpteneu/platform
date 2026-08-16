import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  client: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.client }));

import { GET } from "./route";

const seasonId = "f1100000-0000-4000-8000-000000000001";

describe("GET /api/stock/overview", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({ role: "kledingcommissie" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: { seasonId, waitlist: [] },
      error: null,
    });
    mocks.client.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("haalt het workspacecontract met historische FIFO-regelsnapshots op", async () => {
    const response = await GET(new Request(`https://tenue.example/api/stock/overview?seasonId=${seasonId}`));

    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("get_inventory_workspace_v2", {
      p_season_id: seasonId,
    });
  });

  it("weigert een ongeldige seizoenparameter voor de RPC", async () => {
    const response = await GET(new Request("https://tenue.example/api/stock/overview?seasonId=ongeldig"));

    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
