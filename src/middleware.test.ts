import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  env: vi.fn(),
  fetchContext: vi.fn(),
}));

vi.mock("@/lib/env", () => ({ getServerEnv: mocks.env }));
vi.mock("@/server/auth/staff-context", () => ({
  fetchStaffContext: mocks.fetchContext,
  STAFF_SESSION_COOKIE: "duindorp_staff_session",
}));

import { middleware } from "./middleware";

function request(path: string, session = false) {
  return new NextRequest(`https://tenue.example${path}`, {
    headers: session
      ? { cookie: "duindorp_staff_session=opaque-session" }
      : undefined,
  });
}

describe("scanner middleware", () => {
  beforeEach(() => {
    mocks.env.mockReset().mockReturnValue({
      APP_BASE_URL: "https://tenue.example",
      NEXT_PUBLIC_SUPABASE_URL: "https://project.supabase.co",
      SUPABASE_SECRET_KEY: "server-key",
    });
    mocks.fetchContext.mockReset().mockResolvedValue({
      userId: "10000000-0000-4000-8000-000000000001",
      role: "uitgifte",
    });
  });

  it.each([
    "/uitgifte/apple-touch-icon.png",
    "/uitgifte/icon-192.png",
    "/uitgifte/icon-512.png",
    "/uitgifte/manifest.webmanifest",
    "/uitgifte/scanner-sw.js",
  ])("laat PII-vrij PWA-asset %s zonder sessie laden", async (path) => {
    const response = await middleware(request(path));
    expect(response.status).toBe(200);
    expect(response.headers.get("x-middleware-next")).toBe("1");
    expect(mocks.env).not.toHaveBeenCalled();
    expect(mocks.fetchContext).not.toHaveBeenCalled();
  });

  it("vereist wel een geldige medewerkerssessie voor de scannerpagina", async () => {
    const response = await middleware(request("/uitgifte"));
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://tenue.example/staff/login",
    );
    expect(response.headers.get("cache-control")).toContain("no-store");
  });

  it("laat uitsluitend beheerder en uitgifte op de scannerpagina", async () => {
    expect((await middleware(request("/uitgifte", true))).status).toBe(200);
    mocks.fetchContext.mockResolvedValueOnce({
      userId: "10000000-0000-4000-8000-000000000002",
      role: "kledingcommissie",
    });
    const response = await middleware(request("/uitgifte", true));
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://tenue.example/backoffice",
    );
  });
});
