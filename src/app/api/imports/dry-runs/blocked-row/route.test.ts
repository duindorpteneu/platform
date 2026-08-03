import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireStaffRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: mocks.serverClient,
}));

import { GET } from "./route";

const runId = "10000000-0000-4000-8000-000000000001";
const batchId = "20000000-0000-4000-8000-000000000001";

describe("GET /api/imports/dry-runs/blocked-row", () => {
  beforeEach(() => {
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      userId: "30000000-0000-4000-8000-000000000001",
      role: "beheerder",
    });
    mocks.rpc.mockReset();
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("levert uitsluitend tijdelijk geselecteerde velden aan de eigenaar", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        runId,
        batchId,
        sourceRow: 8,
        reasonCodes: ["identity_ambiguous"],
        fields: {
          first_name: "Voorbeeld",
          last_name: "Lid",
          date_of_birth: "2017-05-05",
        },
        sizes: [{
          articleId: "40000000-0000-4000-8000-000000000001",
          articleName: "Broek",
          sourceValue: "XXXL",
        }],
        expiresAt: "2026-08-04T10:00:00.000Z",
      },
      error: null,
    });
    const response = await GET(new Request(
      `https://tenue.example/api/imports/dry-runs/blocked-row?runId=${runId}&sourceRow=8`,
    ));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(await response.json()).toMatchObject({
      sourceRow: 8,
      reasonCodes: ["identity_ambiguous"],
    });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_dynamic_import_blocked_row",
      { p_run_id: runId, p_source_row: 8 },
    );
  });

  it("faalt gesloten voor ongeldige of verlopen details", async () => {
    const invalid = await GET(new Request(
      `https://tenue.example/api/imports/dry-runs/blocked-row?runId=${runId}&sourceRow=1`,
    ));
    expect(invalid.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "P0002" },
    });
    const expired = await GET(new Request(
      `https://tenue.example/api/imports/dry-runs/blocked-row?runId=${runId}&sourceRow=8`,
    ));
    expect(expired.status).toBe(404);
  });

  it("vertaalt autorisatie naar een generieke 403 zonder detaillek", async () => {
    mocks.requireStaffRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await GET(new Request(
      `https://tenue.example/api/imports/dry-runs/blocked-row?runId=${runId}&sourceRow=8`,
    ));
    expect(response.status).toBe(403);
    expect(JSON.stringify(await response.json())).not.toMatch(/Voorbeeld|2017/);
  });
});
