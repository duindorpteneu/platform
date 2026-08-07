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

function request(body: unknown) {
  return new Request("https://tenue.example/api/action-items/resolve", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/action-items/resolve", () => {
  beforeEach(() => {
    mocks.guard.mockReset().mockReturnValue(null);
    mocks.mutate.mockReset().mockResolvedValue({
      data: null,
      error: {
        code: "23514",
        message: "ACTION_ITEM_DOMAIN_REPAIR_REQUIRED",
      },
    });
  });

  it("normaliseert de aanvraag maar weigert vrije-tekst-resolve", async () => {
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 5,
      reason: "  Maat gekoppeld aan bestaande variant  ",
    }));
    expect(response.status).toBe(409);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.mutate).toHaveBeenCalledWith({
      operation: "resolve",
      input: {
        actionItemId: itemId,
        expectedRevision: 5,
        reason: "Maat gekoppeld aan bestaande variant",
      },
    }, null);
  });

  it("weigert een lege oplossing en vertaalt ontbrekend naar 404", async () => {
    expect((await POST(request({
      actionItemId: itemId,
      expectedRevision: 5,
      reason: "x",
    }))).status).toBe(400);
    expect(mocks.mutate).not.toHaveBeenCalled();

    mocks.mutate.mockResolvedValueOnce({
      data: null,
      error: { code: "P0002", message: "intern" },
    });
    expect((await POST(request({
      actionItemId: itemId,
      expectedRevision: 5,
      reason: "Niet meer van toepassing",
    }))).status).toBe(404);
  });
});
