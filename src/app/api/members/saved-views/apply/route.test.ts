import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ apply: vi.fn() }));

vi.mock("@/server/members/saved-views", () => ({
  applyMemberSavedView: mocks.apply,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const seasonId = "71000000-0000-4000-8000-000000000001";
const viewId = "78000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request(
    "https://tenue.example/api/members/saved-views/apply",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Duindorp-CSRF": "same-origin",
      },
      body: JSON.stringify(body),
    },
  );
}

describe("POST /api/members/saved-views/apply", () => {
  beforeEach(() => {
    mocks.apply.mockReset().mockResolvedValue({
      data: {
        id: viewId,
        seasonId,
        schemaVersion: 1,
        filters: { team: "JO11-1", lineStatus: "backorder" },
      },
      error: null,
    });
  });

  it("past uitsluitend de server-side opnieuw gevalideerde filters toe", async () => {
    const response = await POST(request({ viewId, seasonId }));
    expect(response.status).toBe(200);
    expect(mocks.apply).toHaveBeenCalledWith({ viewId, seasonId });
    expect(await response.json()).toEqual({
      id: viewId,
      seasonId,
      schemaVersion: 1,
      filters: { team: "JO11-1", lineStatus: "backorder" },
    });
  });

  it("stuurt bij een stale preset geen gedeeltelijke filters terug", async () => {
    mocks.apply.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "SAVED_VIEW_STALE" },
    });
    const response = await POST(request({ viewId, seasonId }));
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "Deze weergave bevat verouderde filters en is niet toegepast.",
    });
  });
});
