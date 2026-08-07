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

import { DELETE, PUT } from "./route";

const ids = {
  draft: "10000000-0000-4000-8000-000000000001",
  variant: "20000000-0000-4000-8000-000000000001",
  request: "30000000-0000-4000-8000-000000000001",
  correlation: "40000000-0000-4000-8000-000000000001",
};
const context = { params: Promise.resolve({ draftId: ids.draft }) };

function request(method: "PUT" | "DELETE", body: unknown) {
  return new Request(`https://tenue.example/api/stock/drafts/${ids.draft}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

describe("/api/stock/drafts/[draftId]", () => {
  beforeEach(() => {
    mocks.guard.mockReset().mockReturnValue(null);
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: { id: ids.draft, revision: 3 },
      error: null,
    });
    mocks.client.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("werkt de volledige maatmatrix met revisiecontrole bij", async () => {
    const response = await PUT(request("PUT", {
      expectedRevision: 2,
      requestId: ids.request,
      lines: [{
        variantId: ids.variant,
        quantity: 0,
        confirmed: true,
      }],
    }), context);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "update_inventory_delivery_draft",
      {
        p_draft_id: ids.draft,
        p_expected_revision: 2,
        p_lines: [{
          variantId: ids.variant,
          quantity: 0,
          confirmed: true,
        }],
        p_request_id: ids.request,
      },
    );
  });

  it("annuleert uitsluitend met reden, request-ID en correlatie", async () => {
    const response = await DELETE(request("DELETE", {
      expectedRevision: 3,
      reason: "Pakbon bleek dubbel ingevoerd",
      requestId: ids.request,
      correlationId: ids.correlation,
    }), context);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "cancel_inventory_delivery_draft",
      {
        p_draft_id: ids.draft,
        p_expected_revision: 3,
        p_reason: "Pakbon bleek dubbel ingevoerd",
        p_request_id: ids.request,
        p_correlation_id: ids.correlation,
      },
    );
  });

  it.each([
    ["P0002", 404],
    ["40001", 409],
    ["42501", 403],
  ])("vertaalt updatefout %s zonder databasecontext", async (code, status) => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code, message: "gevoelige databasecontext" },
    });
    const response = await PUT(request("PUT", {
      expectedRevision: 2,
      requestId: ids.request,
      lines: [{
        variantId: ids.variant,
        quantity: 1,
        confirmed: true,
      }],
    }), context);
    expect(response.status).toBe(status);
    expect(await response.text()).not.toContain("gevoelige");
  });

  it("weigert ongeldige params en ontbrekende database", async () => {
    const invalidContext = { params: Promise.resolve({ draftId: "ongeldig" }) };
    expect((await PUT(request("PUT", {
      expectedRevision: 2,
      requestId: ids.request,
      lines: [{
        variantId: ids.variant,
        quantity: 1,
        confirmed: true,
      }],
    }), invalidContext)).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.client.mockResolvedValueOnce(null);
    expect((await DELETE(request("DELETE", {
      expectedRevision: 3,
      reason: "Pakbon bleek dubbel ingevoerd",
      requestId: ids.request,
    }), context)).status).toBe(503);
  });
});
