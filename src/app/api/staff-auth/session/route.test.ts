import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  context: vi.fn(),
  serverClient: vi.fn(),
}));

vi.mock("@/server/auth/staff", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/server/auth/staff")>();
  return { ...actual, getStaffContext: mocks.context };
});

vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: mocks.serverClient,
}));

import { GET, POST } from "./route";

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

function synchronizedClient(options: { level?: string; role?: string } = {}) {
  const query = {
    select: vi.fn(),
    eq: vi.fn(),
    maybeSingle: vi.fn().mockResolvedValue({ data: { role: options.role ?? "beheerder", active: true } }),
  };
  query.select.mockReturnValue(query);
  query.eq.mockReturnValue(query);
  return {
    auth: {
      setSession: vi.fn().mockResolvedValue({
        data: { session: { access_token: "verified" }, user: { id: "00000000-0000-4000-8000-000000000001" } },
        error: null,
      }),
      mfa: { getAuthenticatorAssuranceLevel: vi.fn().mockResolvedValue({ data: { currentLevel: options.level ?? "aal2" }, error: null }) },
    },
    schema: vi.fn().mockReturnValue({ from: vi.fn().mockReturnValue(query) }),
  };
}

describe("GET /api/staff-auth/session", () => {
  beforeEach(() => {
    mocks.context.mockReset();
    mocks.serverClient.mockReset();
    process.env.APP_BASE_URL = "https://tenue.example";
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
    const client = synchronizedClient({ role: "uitgifte" });
    mocks.serverClient.mockResolvedValue(client);

    const response = await POST(synchronizationRequest({
      accessToken: "a".repeat(32),
      refreshToken: "r".repeat(12),
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ landingPath: "/uitgifte" });
    expect(client.auth.setSession).toHaveBeenCalledWith({
      access_token: "a".repeat(32),
      refresh_token: "r".repeat(12),
    });
  });

  it("weigert een gesynchroniseerde sessie die geen AAL2 bereikt", async () => {
    mocks.serverClient.mockResolvedValue(synchronizedClient({ level: "aal1" }));

    const response = await POST(synchronizationRequest({
      accessToken: "a".repeat(32),
      refreshToken: "r".repeat(32),
    }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "STAFF_AAL2_REQUIRED" });
  });
});
