import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fetchStaffContext } from "@/server/auth/staff-context";

const context = {
  userId: "00000000-0000-4000-8000-000000000001",
  displayName: "Testmedewerker",
  role: "beheerder",
  activeSeason: null,
};

describe("staff PostgREST context", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "publishable-test-key";
  });

  afterEach(() => vi.unstubAllGlobals());

  it("stuurt het user-token rechtstreeks naar het afgeschermde app-RPC", async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json(context));
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchStaffContext("verified-user-jwt")).resolves.toEqual(context);
    expect(fetchMock).toHaveBeenCalledWith(
      new URL("https://project.supabase.co/rest/v1/rpc/get_staff_auth_context"),
      expect.objectContaining({
        method: "POST",
        cache: "no-store",
        headers: expect.objectContaining({
          apikey: "publishable-test-key",
          Authorization: "Bearer verified-user-jwt",
          "Content-Profile": "app",
        }),
      }),
    );
  });

  it("faalt gesloten bij een weigering of ongeldig antwoord", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json({ code: "42501" }, { status: 403 }))
      .mockResolvedValueOnce(Response.json({ role: "beheerder" }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchStaffContext("aal1-token")).resolves.toBeNull();
    await expect(fetchStaffContext("malformed-token")).resolves.toBeNull();
  });
});
