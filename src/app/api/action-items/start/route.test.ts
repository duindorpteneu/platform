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
  return new Request("https://tenue.example/api/action-items/start", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/action-items/start", () => {
  beforeEach(() => {
    mocks.guard.mockReset().mockReturnValue(null);
    mocks.mutate.mockReset().mockResolvedValue({
      data: { id: itemId, status: "in_progress" },
      error: null,
    });
  });

  it("start uitsluitend de verwachte revisie en retourneert no-store", async () => {
    const response = await POST(request({
      actionItemId: itemId,
      expectedRevision: 4,
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.mutate).toHaveBeenCalledWith({
      operation: "start",
      input: { actionItemId: itemId, expectedRevision: 4 },
    }, null);
  });

  it("blokkeert een guardresponse en een stale revisie fail-closed", async () => {
    mocks.guard.mockReturnValueOnce(new Response(null, { status: 403 }));
    expect((await POST(request({ invalid: true }))).status).toBe(403);
    expect(mocks.mutate).not.toHaveBeenCalled();

    mocks.guard.mockReturnValue(null);
    mocks.mutate.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "intern" },
    });
    expect((await POST(request({
      actionItemId: itemId,
      expectedRevision: 4,
    }))).status).toBe(409);
  });
});
