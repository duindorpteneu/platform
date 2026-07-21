import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  cookieGet: vi.fn(),
  revoke: vi.fn(),
}));

vi.mock("next/headers", () => ({
  cookies: vi.fn(async () => ({ get: mocks.cookieGet })),
}));

vi.mock("@/server/auth/staff-context", () => ({
  revokeStaffSession: mocks.revoke,
  STAFF_SESSION_COOKIE: "duindorp_staff_session",
}));

import { POST } from "./route";

function logoutRequest(csrf = "same-origin") {
  return new Request("https://tenue.example/api/staff-auth/logout", {
    method: "POST",
    headers: {
      Origin: "https://tenue.example",
      Host: "tenue.example",
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": csrf,
    },
  });
}

describe("POST /api/staff-auth/logout", () => {
  beforeEach(() => {
    mocks.cookieGet.mockReset();
    mocks.revoke.mockReset();
    process.env.APP_BASE_URL = "https://tenue.example";
  });

  it("trekt de server-side sessie in en wist de HttpOnly-cookie", async () => {
    mocks.cookieGet.mockReturnValue({ value: "a".repeat(64) });
    mocks.revoke.mockResolvedValue(true);

    const response = await POST(logoutRequest());

    expect(response.status).toBe(204);
    expect(mocks.revoke).toHaveBeenCalledWith("a".repeat(64));
    expect(response.headers.get("set-cookie")).toContain("duindorp_staff_session=");
    expect(response.headers.get("set-cookie")).toContain("HttpOnly");
    expect(response.headers.get("set-cookie")).toContain("Max-Age=0");
  });

  it("weigert een cross-site uitlogmutatie", async () => {
    const response = await POST(logoutRequest("cross-site"));

    expect(response.status).toBe(403);
    expect(mocks.revoke).not.toHaveBeenCalled();
  });
});
