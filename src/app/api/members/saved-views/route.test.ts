import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  save: vi.fn(),
  remove: vi.fn(),
}));

vi.mock("@/server/members/saved-views", () => ({
  saveMemberSavedView: mocks.save,
  deleteMemberSavedView: mocks.remove,
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { DELETE, POST } from "./route";

const seasonId = "71000000-0000-4000-8000-000000000001";
const viewId = "78000000-0000-4000-8000-000000000001";

function request(method: "POST" | "DELETE", body: unknown) {
  return new Request("https://tenue.example/api/members/saved-views", {
    method,
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

const savedView = {
  id: viewId,
  scope: "members",
  seasonId,
  name: "JO11 openstaand",
  schemaVersion: 1,
  filters: { team: "JO11-1", payment: "unpaid" },
  valid: true,
  invalidReason: null,
  updatedAt: "2026-08-03T20:00:00.000Z",
};

describe("/api/members/saved-views", () => {
  beforeEach(() => {
    mocks.save.mockReset().mockResolvedValue({
      data: savedView,
      error: null,
    });
    mocks.remove.mockReset().mockResolvedValue({
      data: { id: viewId, seasonId, deleted: true },
      error: null,
    });
  });

  it("slaat uitsluitend het strikte filtercontract op", async () => {
    const response = await POST(request("POST", {
      viewId: null,
      seasonId,
      name: " JO11 openstaand ",
      schemaVersion: 1,
      filters: { team: "JO11-1", payment: "unpaid" },
    }));

    expect(response.status).toBe(200);
    expect(mocks.save).toHaveBeenCalledWith({
      viewId: null,
      seasonId,
      name: "JO11 openstaand",
      schemaVersion: 1,
      filters: { team: "JO11-1", payment: "unpaid" },
    });
    expect(response.headers.get("cache-control")).toContain("no-store");
  });

  it("weigert vrije zoektekst voordat een RPC wordt aangeroepen", async () => {
    const response = await POST(request("POST", {
      viewId: null,
      seasonId,
      name: "Onveilig",
      schemaVersion: 1,
      filters: { search: "Sophie" },
    }));

    expect(response.status).toBe(400);
    expect(mocks.save).not.toHaveBeenCalled();
  });

  it("vertaalt een verouderd filter fail-closed naar conflict", async () => {
    mocks.save.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "gevoelige databasecontext" },
    });
    const response = await POST(request("POST", {
      viewId: null,
      seasonId,
      name: "Oud team",
      schemaVersion: 1,
      filters: { team: "JO99-9" },
    }));

    expect(response.status).toBe(409);
    expect(await response.text()).not.toContain("gevoelige databasecontext");
  });

  it("verwijdert alleen een expliciete view binnen hetzelfde seizoen", async () => {
    const response = await DELETE(request("DELETE", { viewId, seasonId }));
    expect(response.status).toBe(200);
    expect(mocks.remove).toHaveBeenCalledWith({ viewId, seasonId });
  });
});
