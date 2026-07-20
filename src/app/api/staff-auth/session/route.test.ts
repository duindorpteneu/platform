import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  context: vi.fn(),
}));

vi.mock("@/server/auth/staff", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/server/auth/staff")>();
  return { ...actual, getStaffContext: mocks.context };
});

import { GET } from "./route";

describe("GET /api/staff-auth/session", () => {
  beforeEach(() => mocks.context.mockReset());

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
});
