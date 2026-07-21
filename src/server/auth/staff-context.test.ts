import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { consumeStaffSessionExchange, fetchStaffContext, revokeStaffSession } from "@/server/auth/staff-context";

const context = {
  userId: "00000000-0000-4000-8000-000000000001",
  displayName: "Testmedewerker",
  role: "beheerder",
  activeSeason: null,
};

describe("staff PostgREST context", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co";
    process.env.SUPABASE_SECRET_KEY = "service-role-test-key";
  });

  afterEach(() => vi.unstubAllGlobals());

  it("valideert de opaque sessie via het service-role staff-RPC", async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json(context));
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchStaffContext("a".repeat(64))).resolves.toEqual(context);
    expect(fetchMock).toHaveBeenCalledWith(
      new URL("https://project.supabase.co/rest/v1/rpc/get_staff_app_session"),
      expect.objectContaining({
        method: "POST",
        cache: "no-store",
        headers: expect.objectContaining({
          apikey: "service-role-test-key",
          Authorization: "Bearer service-role-test-key",
          "Content-Profile": "app",
        }),
      }),
    );
  });

  it("consumeert een exchange en kan de resulterende sessie intrekken", async () => {
    const consumed = { sessionToken: "b".repeat(64), context };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json(consumed))
      .mockResolvedValueOnce(Response.json(1));
    vi.stubGlobal("fetch", fetchMock);

    await expect(consumeStaffSessionExchange("a".repeat(64))).resolves.toEqual(consumed);
    await expect(revokeStaffSession("b".repeat(64))).resolves.toBe(true);
    expect(fetchMock.mock.calls[0]?.[0]).toEqual(new URL("https://project.supabase.co/rest/v1/rpc/consume_staff_session_exchange"));
    expect(fetchMock.mock.calls[1]?.[0]).toEqual(new URL("https://project.supabase.co/rest/v1/rpc/revoke_staff_app_session"));
  });

  it("faalt gesloten bij een weigering of ongeldig antwoord", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json({ code: "42501" }, { status: 403 }))
      .mockResolvedValueOnce(Response.json({ role: "beheerder" }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchStaffContext("a".repeat(64))).resolves.toBeNull();
    await expect(fetchStaffContext("b".repeat(64))).resolves.toBeNull();
  });
});
