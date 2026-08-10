import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  server: vi.fn(),
  getUser: vi.fn(),
  revokeAll: vi.fn(),
}));

vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.server }));
vi.mock("@/server/auth/staff-context", () => ({
  STAFF_SESSION_COOKIE: "duindorp_staff_session",
  StaffSessionUnavailableError: class StaffSessionUnavailableError extends Error {},
  revokeAllStaffSessionsForUser: mocks.revokeAll,
}));

import { POST } from "./route";

const userId = "00000000-0000-4000-8000-000000000001";
function changedRequest(body?: BodyInit) {
  return new Request("https://tenue.example/api/staff-auth/password-changed", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
    },
    body,
    duplex: "half",
  } as RequestInit & { duplex: "half" });
}

describe("POST /api/staff-auth/password-changed", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.getUser.mockReset().mockResolvedValue({ data: { user: { id: userId } }, error: null });
    mocks.server.mockReset().mockResolvedValue({ auth: { getUser: mocks.getUser } });
    mocks.revokeAll.mockReset().mockResolvedValue({ sessionsRevoked: 1, exchangesConsumed: 0, scanGrantsRevoked: 1 });
  });

  it("verifieert de recovery-user, trekt alle appsessies in en wist de cookie", async () => {
    const response = await POST(changedRequest());
    expect(response.status).toBe(204);
    expect(mocks.revokeAll).toHaveBeenCalledWith(userId);
    expect(response.headers.get("set-cookie")).toContain("duindorp_staff_session=");
    expect(response.headers.get("set-cookie")).toContain("Max-Age=0");
  });

  it("faalt gesloten zonder geverifieerde Supabase-user of staffprofiel", async () => {
    mocks.getUser.mockResolvedValueOnce({ data: { user: null }, error: new Error("invalid") });
    expect((await POST(changedRequest())).status).toBe(401);
    expect(mocks.revokeAll).not.toHaveBeenCalled();

    mocks.getUser.mockResolvedValueOnce({ data: { user: { id: userId } }, error: null });
    mocks.revokeAll.mockResolvedValueOnce(null);
    expect((await POST(changedRequest())).status).toBe(403);
  });

  it("weigert requestbodies vóór sessiemutatie", async () => {
    const response = await POST(changedRequest("x"));
    expect(response.status).toBe(413);
    expect(mocks.getUser).not.toHaveBeenCalled();
  });
});
