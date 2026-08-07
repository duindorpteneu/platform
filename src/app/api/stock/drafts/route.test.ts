import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  guard: vi.fn(),
  requireRole: vi.fn(),
  client: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: mocks.client,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: mocks.guard,
}));

import { POST } from "./route";

const ids = {
  season: "10000000-0000-4000-8000-000000000001",
  article: "20000000-0000-4000-8000-000000000001",
  request: "30000000-0000-4000-8000-000000000001",
};
const body = {
  seasonId: ids.season,
  receivedOn: "2026-08-07",
  supplier: "Free-Kick Sport",
  packingSlipReference: "Pakbon 42",
  articleIds: [ids.article],
  requestId: ids.request,
};

function request(candidate: unknown) {
  return new Request("https://tenue.example/api/stock/drafts", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(candidate),
  });
}

describe("POST /api/stock/drafts", () => {
  beforeEach(() => {
    mocks.guard.mockReset().mockReturnValue(null);
    mocks.requireRole.mockReset().mockResolvedValue({
      role: "kledingcommissie",
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: { id: ids.request, revision: 1 },
      error: null,
    });
    mocks.client.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("maakt het concept via het exacte transactionele RPC-contract", async () => {
    const response = await POST(request(body));
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireRole).toHaveBeenCalledWith([
      "beheerder",
      "kledingcommissie",
    ]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "create_inventory_delivery_draft",
      {
        p_season_id: ids.season,
        p_received_on: "2026-08-07",
        p_supplier: "Free-Kick Sport",
        p_packing_slip_reference: "Pakbon 42",
        p_article_ids: [ids.article],
        p_request_id: ids.request,
      },
    );
  });

  it("blokkeert guard, rol, duplicaten en database-unavailable vóór mutatie", async () => {
    mocks.guard.mockReturnValueOnce(new Response(null, { status: 403 }));
    expect((await POST(request({ invalid: true }))).status).toBe(403);
    expect(mocks.requireRole).not.toHaveBeenCalled();

    mocks.guard.mockReturnValue(null);
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    expect((await POST(request(body))).status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.requireRole.mockResolvedValue({ role: "beheerder" });
    expect((await POST(request({
      ...body,
      articleIds: [ids.article, ids.article],
    }))).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.client.mockResolvedValueOnce(null);
    expect((await POST(request(body))).status).toBe(503);
  });

  it.each([
    ["42501", 403],
    ["23514", 409],
    ["23505", 409],
    ["unexpected", 409],
  ])("vertaalt RPC-code %s veilig", async (code, status) => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code, message: "gevoelige databasecontext" },
    });
    const response = await POST(request(body));
    expect(response.status).toBe(status);
    expect(await response.text()).not.toContain("gevoelige");
  });
});
