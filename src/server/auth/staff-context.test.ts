import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createStaffSessionForUser, fetchStaffContext, revokeAllStaffSessionsForUser, revokeStaffSession, StaffSessionUnavailableError } from "@/server/auth/staff-context";

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

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

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

  it("maakt na tokenverificatie een sessie voor de database-user en kan die intrekken", async () => {
    const consumed = { sessionToken: "b".repeat(64), context };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json(consumed))
      .mockResolvedValueOnce(Response.json(1));
    vi.stubGlobal("fetch", fetchMock);

    await expect(createStaffSessionForUser(context.userId)).resolves.toEqual(consumed);
    await expect(revokeStaffSession("b".repeat(64))).resolves.toBe(true);
    expect(fetchMock.mock.calls[0]?.[0]).toEqual(new URL("https://project.supabase.co/rest/v1/rpc/create_staff_app_session_for_user"));
    expect(fetchMock.mock.calls[1]?.[0]).toEqual(new URL("https://project.supabase.co/rest/v1/rpc/revoke_staff_app_session"));
  });

  it("trekt na wachtwoordherstel alle app-sessies en scangrants van de user in", async () => {
    const result = { sessionsRevoked: 2, exchangesConsumed: 1, scanGrantsRevoked: 3 };
    const fetchMock = vi.fn().mockResolvedValue(Response.json(result));
    vi.stubGlobal("fetch", fetchMock);

    await expect(revokeAllStaffSessionsForUser(context.userId)).resolves.toEqual(result);
    expect(fetchMock).toHaveBeenCalledWith(
      new URL("https://project.supabase.co/rest/v1/rpc/revoke_all_staff_app_sessions_for_user"),
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ p_auth_user_id: context.userId }),
      }),
    );
  });

  it("faalt gesloten bij een weigering of ongeldig antwoord", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json({ code: "42501" }, { status: 403 }))
      .mockResolvedValueOnce(Response.json({ role: "beheerder" }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchStaffContext("a".repeat(64))).resolves.toBeNull();
    await expect(fetchStaffContext("b".repeat(64))).resolves.toBeNull();
  });

  it("onderscheidt een transportfout tijdens sessie-uitgifte van een autorisatieweigering", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network unavailable")));
    await expect(createStaffSessionForUser(context.userId)).rejects.toBeInstanceOf(StaffSessionUnavailableError);
  });

  it("houdt de transportdeadline actief totdat de PostgREST-body volledig is gelezen", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve({
      ok: true,
      json: () => new Promise(() => undefined),
    }));
    vi.stubGlobal("fetch", fetchMock);

    const pending = createStaffSessionForUser(context.userId);
    const assertion = expect(pending).rejects.toBeInstanceOf(StaffSessionUnavailableError);
    await vi.advanceTimersByTimeAsync(10_000);

    await assertion;
  });
});
