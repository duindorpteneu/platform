import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  requireSession: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/supplier", () => ({
  requireSupplierSessionBinding: mocks.requireSession,
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));

import { GET } from "./route";

const seasonId = "10000000-0000-4000-8000-000000000001";
const planning = {
  season: { id: seasonId, name: "2026/2027" },
  generatedAt: "2026-08-03T12:00:00.000Z",
  lowStockThreshold: 10,
  inventory: [{
    productName: "Broek",
    productCode: "BROEK",
    size: "M",
    supplierCode: "BR-M",
    productActive: true,
    variantActive: true,
    physical: 4,
    reserved: 1,
    issued: 2,
    free: 3,
    totalOpenDemand: 5,
    shortage: 1,
  }],
  demandByGender: [{
    productName: "Broek",
    productCode: "BROEK",
    size: "M",
    supplierCode: "BR-M",
    gender: "unknown",
    totalOpenDemand: 5,
    paidWaiting: 2,
    unpaidDemand: 3,
    unconfirmedDemand: 0,
    pickedUp: 2,
  }],
  unresolvedSizeDemand: [],
};

describe("GET /api/supplier/planning", () => {
  beforeEach(() => {
    mocks.requireSession.mockReset().mockResolvedValue({
      principalId: "20000000-0000-4000-8000-000000000001",
      displayName: "Free-Kick",
      sessionTokenHash: "a".repeat(64),
    });
    mocks.rpc.mockReset().mockResolvedValue({ data: planning, error: null });
    mocks.admin.mockReset().mockReturnValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("roept alleen de dedicated season-bound aggregate-RPC aan", async () => {
    const response = await GET(new Request(
      `https://tenue.example/api/supplier/planning?seasonId=${seasonId}`,
      {
        headers: {
          "X-Correlation-Id":
            "30000000-0000-4000-8000-000000000001",
        },
      },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(planning);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_supplier_planning_v1",
      {
        p_correlation_id: "30000000-0000-4000-8000-000000000001",
        p_season_id: seasonId,
        p_session_token_hash: "a".repeat(64),
      },
    );
    expect(response.headers.get("cache-control")).toContain("no-store");
  });

  it("weigert ongeldige en niet-verleende seizoenen zonder details", async () => {
    expect((await GET(new Request(
      "https://tenue.example/api/supplier/planning?seasonId=invalid",
    ))).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "P0002", message: "database detail" },
    });
    const response = await GET(new Request(
      `https://tenue.example/api/supplier/planning?seasonId=${seasonId}`,
    ));
    expect(response.status).toBe(404);
    expect(await response.text()).not.toContain("database detail");
  });

  it("faalt gesloten bij extra individuele velden in de RPC-response", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { ...planning, memberName: "Verboden" },
      error: null,
    });
    const response = await GET(new Request(
      `https://tenue.example/api/supplier/planning?seasonId=${seasonId}`,
    ));
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("Verboden");
  });

  it("leest niets wanneer de suppliersessie ontbreekt", async () => {
    mocks.requireSession.mockRejectedValueOnce(
      new Error("SUPPLIER_AUTHORIZATION_REQUIRED"),
    );
    const response = await GET(new Request(
      `https://tenue.example/api/supplier/planning?seasonId=${seasonId}`,
    ));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
