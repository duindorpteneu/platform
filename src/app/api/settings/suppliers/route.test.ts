import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  generateToken: vi.fn(),
  hashToken: vi.fn(),
  requireSession: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffSessionBinding: mocks.requireSession,
}));
vi.mock("@/server/auth/supplier-context", () => ({
  generateSupplierAccessToken: mocks.generateToken,
  hashSupplierSecret: mocks.hashToken,
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));

import { GET, POST } from "./route";

const seasonId = "10000000-0000-4000-8000-000000000001";
const principalId = "20000000-0000-4000-8000-000000000001";
const requestId = "30000000-0000-4000-8000-000000000001";
const accessToken = `dsv_supplier_${"a".repeat(43)}`;
const principal = {
  id: principalId,
  displayName: "Free-Kick planning",
  active: true,
  tokenVersion: 1,
  createdAt: "2026-08-03T12:00:00.000Z",
  updatedAt: "2026-08-03T12:00:00.000Z",
  disabledAt: null,
  seasonIds: [seasonId],
  activeSessions: 0,
  lastUsedAt: null,
};

function mutation(body: unknown) {
  const serialized = JSON.stringify(body);
  return new Request("https://tenue.example/api/settings/suppliers", {
    method: "POST",
    headers: {
      "Content-Length": String(Buffer.byteLength(serialized)),
      "Content-Type": "application/json",
      Host: "tenue.example",
      Origin: "https://tenue.example",
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: serialized,
  });
}

describe("supplier access management route", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.requireSession.mockReset().mockResolvedValue({
      userId: "40000000-0000-4000-8000-000000000001",
      role: "beheerder",
      sessionTokenHash: "b".repeat(64),
    });
    mocks.generateToken.mockReset().mockReturnValue(accessToken);
    mocks.hashToken.mockReset().mockResolvedValue("c".repeat(64));
    mocks.rpc.mockReset();
    mocks.admin.mockReset().mockReturnValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("leest alleen via de gebonden beheerderssessie", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        principals: [principal],
        seasons: [{ id: seasonId, name: "2026/2027", status: "open" }],
      },
      error: null,
    });
    const response = await GET();
    expect(response.status).toBe(200);
    expect(mocks.requireSession).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_supplier_planner_admin_workspace_v1",
      {
        p_actor_id: "40000000-0000-4000-8000-000000000001",
        p_staff_session_hash: "b".repeat(64),
      },
    );
  });

  it("toont een nieuwe high-entropy sleutel precies bij de eerste create-response", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        action: "create",
        alreadyProcessed: false,
        principal,
      },
      error: null,
    });
    const response = await POST(mutation({
      action: "create",
      displayName: "Free-Kick planning",
      seasonIds: [seasonId],
      requestId,
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      action: "create",
      alreadyProcessed: false,
      principal,
      accessToken,
    });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "manage_supplier_planner_v1",
      expect.objectContaining({
        p_access_token_hash: "c".repeat(64),
        p_action: "create",
        p_season_ids: [seasonId],
        p_staff_session_hash: "b".repeat(64),
      }),
    );
  });

  it("geeft bij een verloren-response replay nooit een nieuwe ongeldige sleutel", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        action: "rotate",
        alreadyProcessed: true,
        principal: { ...principal, tokenVersion: 2 },
      },
      error: null,
    });
    const response = await POST(mutation({
      action: "rotate",
      principalId,
      reason: "Periodieke sleutelrotatie",
      requestId,
    }));
    const payload = await response.json();
    expect(payload.accessToken).toBeUndefined();
    expect(JSON.stringify(payload)).not.toContain(accessToken);
  });

  it("blokkeert niet-beheerders vóór de service-RPC", async () => {
    mocks.requireSession.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(mutation({
      action: "disable",
      principalId,
      reason: "Samenwerking beëindigd",
      requestId,
    }));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
