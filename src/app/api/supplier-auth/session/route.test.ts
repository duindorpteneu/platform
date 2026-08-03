import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  context: vi.fn(),
  create: vi.fn(),
}));

vi.mock("@/server/auth/supplier", () => ({
  getSupplierContext: mocks.context,
}));
vi.mock("@/server/auth/supplier-context", () => ({
  createSupplierSession: mocks.create,
  SUPPLIER_SESSION_COOKIE: "duindorp_supplier_session",
}));

import { GET, POST } from "./route";

const accessToken = `dsv_supplier_${"a".repeat(43)}`;

function loginRequest(token = accessToken) {
  const body = JSON.stringify({ accessToken: token });
  return new Request("https://tenue.example/api/supplier-auth/session", {
    method: "POST",
    headers: {
      "Content-Length": String(Buffer.byteLength(body)),
      "Content-Type": "application/json",
      Host: "tenue.example",
      Origin: "https://tenue.example",
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
      "X-Forwarded-For": "192.0.2.10",
    },
    body,
  });
}

describe("supplier session route", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.context.mockReset().mockResolvedValue(null);
    mocks.create.mockReset().mockResolvedValue({
      sessionToken: "b".repeat(43),
      context: {
        principalId: "10000000-0000-4000-8000-000000000001",
        displayName: "Free-Kick planning",
        expiresAt: "2026-08-03T18:00:00.000Z",
      },
    });
  });

  it("wisselt de sleutel via POST om voor een HttpOnly suppliersessie", async () => {
    const response = await POST(loginRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ landingPath: "/leverancier" });
    expect(mocks.create).toHaveBeenCalledWith(accessToken, "192.0.2.10");
    expect(response.headers.get("set-cookie")).toContain(
      "duindorp_supplier_session=",
    );
    expect(response.headers.get("set-cookie")).toContain("HttpOnly");
    expect(response.headers.get("set-cookie")).toContain("SameSite=lax");
    expect(response.headers.get("cache-control")).toContain("no-store");
  });

  it.each([
    ["ongeldig", "not-a-token"],
    ["ingetrokken", accessToken],
  ])("geeft dezelfde foutgrens voor een %s token", async (_case, token) => {
    if (token === accessToken) mocks.create.mockResolvedValueOnce(null);
    const response = await POST(loginRequest(token));
    expect(response.status).toBe(403);
    const payload = await response.json();
    expect(payload).toEqual({
      error: "SUPPLIER_ACCESS_REJECTED",
    });
    expect(JSON.stringify(payload)).not.toContain(token);
  });

  it("blokkeert cross-origin en oversized bodies vóór authenticatie", async () => {
    const crossOrigin = loginRequest();
    crossOrigin.headers.set("Origin", "https://evil.example");
    expect((await POST(crossOrigin)).status).toBe(403);
    expect(mocks.create).not.toHaveBeenCalled();

    const huge = loginRequest();
    huge.headers.set("Content-Length", "999999");
    expect((await POST(huge)).status).toBe(413);
    expect(mocks.create).not.toHaveBeenCalled();
  });

  it("GET onthult alleen de vaste landing wanneer de sessie geldig is", async () => {
    expect((await GET()).status).toBe(403);
    mocks.context.mockResolvedValueOnce({
      principalId: "10000000-0000-4000-8000-000000000001",
      displayName: "Free-Kick planning",
      activeSeason: null,
      seasons: [],
    });
    const response = await GET();
    expect(await response.json()).toEqual({ landingPath: "/leverancier" });
  });
});
