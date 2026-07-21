import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  context: vi.fn(),
  createClient: vi.fn(),
}));

vi.mock("@/server/auth/staff", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/server/auth/staff")>();
  return { ...actual, getStaffContext: mocks.context };
});

vi.mock("@supabase/supabase-js", () => ({ createClient: mocks.createClient }));

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

function synchronizedClient(options: { authorized?: boolean; role?: "beheerder" | "kledingcommissie" | "uitgifte" } = {}) {
  const rpc = vi.fn().mockResolvedValue(options.authorized === false
    ? { data: null, error: { code: "42501" } }
    : {
        data: {
          userId: "00000000-0000-4000-8000-000000000001",
          displayName: "Testmedewerker",
          role: options.role ?? "beheerder",
          activeSeason: null,
        },
        error: null,
      });
  return {
    rpc,
    schema: vi.fn().mockReturnValue({ rpc }),
  };
}

describe("GET /api/staff-auth/session", () => {
  beforeEach(() => {
    mocks.context.mockReset();
    mocks.createClient.mockReset();
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
    const client = synchronizedClient({ role: "uitgifte" });
    mocks.createClient.mockReturnValue(client);

    const response = await POST(synchronizationRequest({
      accessToken: "a".repeat(32),
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ landingPath: "/uitgifte" });
    expect(client.rpc).toHaveBeenCalledWith("get_staff_auth_context");
    expect(mocks.createClient).toHaveBeenCalledWith(
      "https://project.supabase.co",
      "publishable-test-key",
      expect.objectContaining({ global: { headers: { Authorization: `Bearer ${"a".repeat(32)}` } } }),
    );
  });

  it("weigert een token dat PostgREST niet als actieve AAL2-medewerker valideert", async () => {
    mocks.createClient.mockReturnValue(synchronizedClient({ authorized: false }));

    const response = await POST(synchronizationRequest({
      accessToken: "a".repeat(32),
    }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "STAFF_SESSION_REJECTED" });
  });
});
