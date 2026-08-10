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
  draft: "10000000-0000-4000-8000-000000000001",
  request: "30000000-0000-4000-8000-000000000001",
  correlation: "40000000-0000-4000-8000-000000000001",
};
const context = { params: Promise.resolve({ draftId: ids.draft }) };
const body = {
  expectedRevision: 4,
  requestId: ids.request,
  correlationId: ids.correlation,
};

function request(candidate: unknown) {
  return new Request(
    `https://tenue.example/api/stock/drafts/${ids.draft}/post`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Duindorp-CSRF": "same-origin",
      },
      body: JSON.stringify(candidate),
    },
  );
}

describe("POST /api/stock/drafts/[draftId]/post", () => {
  beforeEach(() => {
    mocks.guard.mockReset().mockReturnValue(null);
    mocks.requireRole.mockReset().mockResolvedValue({
      role: "kledingcommissie",
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: { id: ids.draft, status: "posted" },
      error: null,
    });
    mocks.client.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("post atomair met revisie, idempotentie en correlatie", async () => {
    const response = await POST(request(body), context);
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "post_inventory_delivery_draft",
      {
        p_draft_id: ids.draft,
        p_expected_revision: 4,
        p_request_id: ids.request,
        p_correlation_id: ids.correlation,
      },
    );
  });

  it.each([
    ["42501", 403],
    ["55000", 409],
    ["P0002", 404],
    ["40001", 409],
  ])("vertaalt postfout %s veilig", async (code, status) => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code, message: "gevoelige databasecontext" },
    });
    const response = await POST(request(body), context);
    expect(response.status).toBe(status);
    expect(await response.text()).not.toContain("gevoelige");
  });

  it("blokkeert guard, rol, ongeldige revisie en database-unavailable", async () => {
    mocks.guard.mockReturnValueOnce(new Response(null, { status: 403 }));
    expect((await POST(request({ invalid: true }), context)).status).toBe(403);
    expect(mocks.requireRole).not.toHaveBeenCalled();

    mocks.guard.mockReturnValue(null);
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    expect((await POST(request(body), context)).status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.requireRole.mockResolvedValue({ role: "beheerder" });
    expect((await POST(request({
      ...body,
      expectedRevision: 0,
    }), context)).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.client.mockResolvedValueOnce(null);
    expect((await POST(request(body), context)).status).toBe(503);
  });
});
