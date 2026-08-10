import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
  logError: vi.fn(),
}));

vi.mock("next/cache", () => ({ unstable_noStore: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: mocks.serverClient,
}));
vi.mock("@/server/security/logger", () => ({
  operationalLogger: { error: mocks.logError },
}));

import { getActionItemWorkspace, mutateActionItem } from "./workspace";

const seasonId = "10000000-0000-4000-8000-000000000001";
const userId = "20000000-0000-4000-8000-000000000001";
const itemId = "30000000-0000-4000-8000-000000000001";

function workspaceResponse() {
  return {
    tenantKey: "duindorp-sv",
    activeSeason: { id: seasonId, name: "2026/27" },
    selectedSeason: { id: seasonId, name: "2026/27", status: "open" },
    seasons: [{
      id: seasonId,
      name: "2026/27",
      status: "open",
      active: true,
    }],
    statusCounts: { open: 0, inProgress: 0, resolved: 0, dismissed: 0 },
    ownerOptions: [{
      userId,
      displayName: "Actiebeheer",
      role: "beheerder",
    }],
    viewer: { userId, role: "beheerder" },
    offset: 0,
    limit: 50,
    total: 0,
    items: [],
  };
}

describe("action item workspace service", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.requireRole.mockResolvedValue({ userId, role: "beheerder" });
    mocks.serverClient.mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("loads one exact season through the bounded workspace RPC", async () => {
    mocks.rpc.mockResolvedValue({ data: workspaceResponse(), error: null });
    const input = {
      seasonId,
      status: "open" as const,
      severity: "critical" as const,
      ownerUserId: null,
      onlyUnassigned: true,
      offset: 0,
      limit: 50 as const,
    };

    const result = await getActionItemWorkspace(input);

    expect(mocks.requireRole).toHaveBeenCalledWith([
      "beheerder",
      "kledingcommissie",
    ]);
    expect(mocks.rpc).toHaveBeenCalledWith("get_action_item_workspace_v2", {
      p_season_id: seasonId,
      p_status: "open",
      p_severity: "critical",
      p_owner_user_id: null,
      p_only_unassigned: true,
      p_offset: 0,
      p_limit: 50,
    });
    expect(result.data?.tenantKey).toBe("duindorp-sv");
  });

  it("dispatches assignment and dismissal to separate revision-checked RPCs", async () => {
    mocks.rpc
      .mockResolvedValueOnce({
        data: {
          id: itemId,
          status: "open",
          ownerUserId: userId,
          revision: 2,
          updatedAt: "2026-08-03T21:00:00+00:00",
          reused: false,
        },
        error: null,
      })
      .mockResolvedValueOnce({
        data: {
          id: itemId,
          status: "dismissed",
          ownerUserId: userId,
          revision: 3,
          updatedAt: "2026-08-03T21:01:00+00:00",
          reused: false,
        },
        error: null,
      });

    await mutateActionItem({
      operation: "assign",
      input: {
        actionItemId: itemId,
        expectedRevision: 1,
        ownerUserId: userId,
      },
    }, null);
    await mutateActionItem({
      operation: "dismiss",
      input: {
        actionItemId: itemId,
        expectedRevision: 2,
        reason: "Bewust afgewezen na controle",
      },
    }, "40000000-0000-4000-8000-000000000001");

    expect(mocks.rpc).toHaveBeenNthCalledWith(1, "assign_action_item", {
      p_action_item_id: itemId,
      p_expected_revision: 1,
      p_owner_user_id: userId,
      p_correlation_id: null,
    });
    expect(mocks.rpc).toHaveBeenNthCalledWith(2, "dismiss_action_item", {
      p_action_item_id: itemId,
      p_expected_revision: 2,
      p_reason: "Bewust afgewezen na controle",
      p_correlation_id: "40000000-0000-4000-8000-000000000001",
    });
  });

  it("routes any legacy resolve request to the domain-only database guard", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: {
        code: "23514",
        message: "ACTION_ITEM_DOMAIN_REPAIR_REQUIRED",
      },
    });
    const result = await mutateActionItem({
      operation: "resolve",
      input: {
        actionItemId: itemId,
        expectedRevision: 4,
        reason: "Domeintoestand handmatig hersteld",
      },
    }, null);
    expect(mocks.rpc).toHaveBeenCalledWith("resolve_action_item_v3", {
      p_action_item_id: itemId,
      p_expected_revision: 4,
      p_reason: "Domeintoestand handmatig hersteld",
      p_correlation_id: null,
    });
    expect(result.error?.code).toBe("23514");
  });

  it("fails closed on an expanded or malformed database response", async () => {
    mocks.rpc.mockResolvedValue({
      data: { ...workspaceResponse(), members: [] },
      error: null,
    });

    await expect(getActionItemWorkspace({
      seasonId,
      status: null,
      severity: null,
      ownerUserId: null,
      onlyUnassigned: false,
      offset: 0,
      limit: 50,
    })).rejects.toThrow("ACTION_ITEM_WORKSPACE_RESPONSE_INVALID");
    expect(mocks.logError).toHaveBeenCalledWith(
      "action_item.workspace_load_failed",
      {
        code: "response_invalid",
        provider: "supabase",
        route: "/backoffice/actiepunten",
      },
    );
  });
});
