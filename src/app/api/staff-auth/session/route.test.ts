import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  context: vi.fn(),
  createSession: vi.fn(),
  verifyToken: vi.fn(),
}));

vi.mock("@/server/auth/staff", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/server/auth/staff")>();
  return { ...actual, getStaffContext: mocks.context };
});

vi.mock("@/server/auth/staff-context", () => ({
  createStaffSessionForUser: mocks.createSession,
  STAFF_SESSION_COOKIE: "duindorp_staff_session",
  StaffSessionUnavailableError: class StaffSessionUnavailableError extends Error {},
}));

vi.mock("@/server/auth/staff-jwt", () => ({
  verifyStaffAal2AccessToken: mocks.verifyToken,
  StaffJwtUnavailableError: class StaffJwtUnavailableError extends Error {},
}));

import { GET, POST } from "./route";
import { StaffSessionUnavailableError } from "@/server/auth/staff-context";
import { StaffJwtUnavailableError } from "@/server/auth/staff-jwt";

function synchronizationRequest(body: unknown) {
  const serialized = JSON.stringify(body);
  return new Request("https://tenue.example/api/staff-auth/session", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": String(Buffer.byteLength(serialized)),
      Origin: "https://tenue.example",
      Host: "tenue.example",
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: serialized,
  });
}

describe("GET /api/staff-auth/session", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  beforeEach(() => {
    mocks.context.mockReset();
    mocks.createSession.mockReset();
    mocks.verifyToken.mockReset();
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "publishable-test-key";
  });

  it("weigert een sessie zonder actief AAL2-medewerkersprofiel", async () => {
    mocks.context.mockResolvedValue(null);

    const response = await GET();

    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toBe("private, no-store, max-age=0");
    expect(await response.json()).toEqual({ error: "STAFF_ACCESS_REQUIRED" });
  });

  it.each([
    ["beheerder", "/backoffice"],
    ["kledingcommissie", "/backoffice"],
    ["uitgifte", "/uitgifte"],
  ] as const)("stuurt %s naar het canonieke werkvlak", async (role, landingPath) => {
    mocks.context.mockResolvedValue({
      userId: "00000000-0000-4000-8000-000000000001",
      displayName: "Testmedewerker",
      role,
      activeSeason: null,
    });

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ landingPath });
  });

  it("valideert een verhoogde sessie server-side en schrijft de rolbestemming terug", async () => {
    vi.stubEnv("NODE_ENV", "production");
    mocks.verifyToken.mockResolvedValue({ userId: "00000000-0000-4000-8000-000000000001" });
    mocks.createSession.mockResolvedValue({
      sessionToken: "b".repeat(64),
      context: {
        userId: "00000000-0000-4000-8000-000000000001",
        displayName: "Testmedewerker",
        role: "uitgifte",
        activeSeason: null,
      },
    });

    const response = await POST(synchronizationRequest({
      accessToken: "header.payload.signature",
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ landingPath: "/uitgifte" });
    expect(mocks.verifyToken).toHaveBeenCalledWith("header.payload.signature");
    expect(mocks.createSession).toHaveBeenCalledWith("00000000-0000-4000-8000-000000000001");
    const cookie = response.headers.get("set-cookie") ?? "";
    expect(cookie).toContain("duindorp_staff_session=");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("Secure");
    expect(cookie.toLowerCase()).toContain("samesite=lax");
    expect(cookie).toContain("Path=/");
    expect(cookie).toContain("Max-Age=28800");
  });

  it("weigert een token dat PostgREST niet als actieve AAL2-medewerker valideert", async () => {
    mocks.verifyToken.mockResolvedValue({ userId: "00000000-0000-4000-8000-000000000001" });
    mocks.createSession.mockResolvedValue(null);

    const response = await POST(synchronizationRequest({
      accessToken: "header.payload.signature",
    }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "STAFF_SESSION_REJECTED" });
    expect(response.headers.get("x-duindorp-auth-error")).toBe("STAFF_SESSION_REJECTED");
  });

  it("weigert een ongeldig, verlopen of niet-AAL2 access-token vóór databasegebruik", async () => {
    mocks.verifyToken.mockResolvedValue(null);

    const response = await POST(synchronizationRequest({ accessToken: "header.payload.signature" }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "STAFF_AAL2_REQUIRED" });
    expect(response.headers.get("x-duindorp-auth-error")).toBe("STAFF_AAL2_REQUIRED");
    expect(mocks.createSession).not.toHaveBeenCalled();
  });

  it.each([
    ["JWT", "STAFF_JWT_UNAVAILABLE", () => mocks.verifyToken.mockRejectedValue(new StaffJwtUnavailableError())],
    ["sessie-RPC", "STAFF_SESSION_UNAVAILABLE", () => {
      mocks.verifyToken.mockResolvedValue({ userId: "00000000-0000-4000-8000-000000000001" });
      mocks.createSession.mockRejectedValue(new StaffSessionUnavailableError());
    }],
  ] as const)(
    "faalt begrensd met 503 wanneer de %s transportlaag niet beschikbaar is",
    async (_stage, errorCode, arrange) => {
      arrange();
      const response = await POST(synchronizationRequest({ accessToken: "header.payload.signature" }));
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: errorCode });
      expect(response.headers.get("x-duindorp-auth-error")).toBe(errorCode);
    },
  );
});
