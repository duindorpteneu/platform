import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock("@/server/action-items/workspace", () => ({
  mutateActionItem: mocks.mutate,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const itemId = "30000000-0000-4000-8000-000000000001";
const userId = "20000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/action-items/dismiss", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
      "X-Correlation-Id": "40000000-0000-4000-8000-000000000001",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/action-items/dismiss", () => {
  beforeEach(() => {
    mocks.mutate.mockReset().mockResolvedValue({
      data: {
        id: itemId,
        status: "dismissed",
        ownerUserId: userId,
        revision: 4,
        updatedAt: "2026-08-03T21:00:00+00:00",
        reused: false,
      },
      staff: { userId, role: "beheerder" },
      error: null,
    });
  });

  it("passes exact revision, reason and normalized correlation to the service", async () => {
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 3,
      reason: "Bewust afgewezen na controle",
    }));

    expect(response.status).toBe(200);
    expect(mocks.mutate).toHaveBeenCalledWith({
      operation: "dismiss",
      input: {
        actionItemId: itemId,
        expectedRevision: 3,
        reason: "Bewust afgewezen na controle",
      },
    }, "40000000-0000-4000-8000-000000000001");
  });

  it("blocks an empty reason before mutation", async () => {
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 3,
      reason: "x",
    }));

    expect(response.status).toBe(400);
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("maps stale revisions to conflict", async () => {
    mocks.mutate.mockResolvedValue({
      data: null,
      staff: { userId, role: "beheerder" },
      error: { code: "40001", message: "ACTION_ITEM_REVISION_CONFLICT" },
    });
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 3,
      reason: "Bewust afgewezen na controle",
    }));

    expect(response.status).toBe(409);
  });
});
