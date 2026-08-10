import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  guard: vi.fn(),
  mutate: vi.fn(),
}));
vi.mock("@/server/action-items/workspace", () => ({
  mutateActionItem: mocks.mutate,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: mocks.guard,
}));

import { POST } from "./route";

const itemId = "30000000-0000-4000-8000-000000000001";
const ownerId = "20000000-0000-4000-8000-000000000001";
const correlationId = "40000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/action-items/assign", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
      "X-Correlation-Id": correlationId,
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/action-items/assign", () => {
  beforeEach(() => {
    mocks.guard.mockReset().mockReturnValue(null);
    mocks.mutate.mockReset().mockResolvedValue({
      data: { id: itemId, status: "open", ownerUserId: ownerId },
      error: null,
    });
  });

  it("bindt eigenaar, revisie en correlatie en retourneert no-store", async () => {
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 3,
      ownerUserId: ownerId,
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.mutate).toHaveBeenCalledWith({
      operation: "assign",
      input: {
        actionItemId: itemId,
        expectedRevision: 3,
        ownerUserId: ownerId,
      },
    }, correlationId);
  });

  it("weigert ongeldige invoer en autorisatiefouten vóór/zonder mutatie", async () => {
    expect((await POST(request({
      actionItemId: itemId,
      expectedRevision: 0,
      ownerUserId: ownerId,
    }))).status).toBe(400);
    expect(mocks.mutate).not.toHaveBeenCalled();

    mocks.guard.mockReturnValueOnce(
      Response.json({ error: "guard" }, { status: 403 }),
    );
    expect((await POST(request({ invalid: true }))).status).toBe(403);
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it.each([
    ["42501", 403],
    ["P0002", 404],
    ["40001", 409],
    ["unexpected", 503],
  ])("vertaalt RPC-code %s zonder details", async (code, status) => {
    mocks.mutate.mockResolvedValueOnce({
      data: null,
      error: { code, message: "gevoelige databasecontext" },
    });
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 3,
      ownerUserId: null,
    }));
    expect(response.status).toBe(status);
    expect(await response.text()).not.toContain("gevoelige");
  });
});
