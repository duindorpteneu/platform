import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("next/cache", () => ({ unstable_noStore: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: mocks.serverClient,
}));

import { getCatalogOrderWorkspace } from "./workspace";

const id = "10000000-0000-4000-8000-000000000001";
const secondId = "10000000-0000-4000-8000-000000000002";
const thirdId = "10000000-0000-4000-8000-000000000003";
const revision = "a".repeat(64);

function databaseWorkspace(extraRequest: Record<string, unknown> = {}) {
  return {
    activeSeason: {
      id,
      name: "2026/2027",
      defaultAmountCents: 12_500,
    },
    articles: [],
    members: [],
    packageFeatureEnabled: true,
    packageRevisions: [],
    packageOrders: [],
    packageSizeChangeRequests: [{
      requestId: secondId,
      memberId: thirdId,
      memberSeasonId: id,
      memberName: "Voornaam Lid",
      team: "JO13-1",
      articleId: secondId,
      articleName: "Broek",
      currentVariantId: id,
      currentSize: "152",
      requestedKind: "other",
      requestedVariantId: null,
      requestedSize: null,
      requestedRawValue: "Anders…",
      requestedMemberNote: "Langere maat nodig",
      requestedAt: "2026-08-02T10:00:00+00:00",
      revision,
      variants: [{ id: thirdId, label: "164" }],
      ...extraRequest,
    }],
  };
}

describe("catalogus- en pakketworkspace", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.requireRole.mockResolvedValue({ role: "beheerder" });
    mocks.serverClient.mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === "get_catalog_order_workspace_v4") {
        return { data: databaseWorkspace(), error: null };
      }
      if (name === "get_catalog_seasons") {
        return {
          data: [{
            id,
            name: "2026/2027",
            status: "open",
            active: true,
          }],
          error: null,
        };
      }
      if (name === "get_member_team_options") {
        return { data: ["JO13-1"], error: null };
      }
      throw new Error(`Onverwachte RPC: ${name}`);
    });
  });

  it("leest uitsluitend het rolgesneden v4-contract", async () => {
    const result = await getCatalogOrderWorkspace();

    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_catalog_order_workspace_v4",
    );
    expect(result.workspace.packageSizeChangeRequests).toHaveLength(1);
  });

  it("wist defensief beheerdernotities voor de kledingcommissie", async () => {
    mocks.requireRole.mockResolvedValue({ role: "kledingcommissie" });

    const result = await getCatalogOrderWorkspace();

    expect(result.workspace.packageSizeChangeRequests).toEqual([]);
  });

  it("weigert onverwachte ouderidentificatie fail-closed", async () => {
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === "get_catalog_order_workspace_v4") {
        return {
          data: databaseWorkspace({ parentAccountId: thirdId }),
          error: null,
        };
      }
      if (name === "get_catalog_seasons") {
        return {
          data: [{
            id,
            name: "2026/2027",
            status: "open",
            active: true,
          }],
          error: null,
        };
      }
      return { data: ["JO13-1"], error: null };
    });

    await expect(getCatalogOrderWorkspace()).rejects.toThrow(
      "CATALOG_WORKSPACE_RESPONSE_INVALID",
    );
  });
});
