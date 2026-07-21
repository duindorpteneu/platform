import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveStaffLandingPath, resolveStaffLandingPathWithRetry, synchronizeStaffSession } from "@/lib/staff-session";

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("staff session landing", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("accepts only a valid staff landing path", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(response({ landingPath: "/backoffice" })));

    await expect(resolveStaffLandingPath()).resolves.toBe("/backoffice");
  });

  it("retries while the server session cookie is synchronizing", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response({ error: "unauthorized" }, 401))
      .mockResolvedValueOnce(response({ landingPath: "/uitgifte" }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(resolveStaffLandingPathWithRetry({ attempts: 3, delayMs: 0 })).resolves.toBe("/uitgifte");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("stops after the configured number of attempts", async () => {
    const fetchMock = vi.fn().mockRejectedValue(new Error("network unavailable"));
    vi.stubGlobal("fetch", fetchMock);

    await expect(resolveStaffLandingPathWithRetry({ attempts: 3, delayMs: 0 })).resolves.toBeNull();
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("rejects a non-JSON response without leaking a parsing exception", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("<html>login</html>", { status: 200 })));

    await expect(resolveStaffLandingPath()).resolves.toBeNull();
  });

  it("synchronizes verified MFA tokens through the same-origin server boundary", async () => {
    const fetchMock = vi.fn().mockResolvedValue(response({ landingPath: "/backoffice" }));
    vi.stubGlobal("fetch", fetchMock);

    const exchangeToken = "a".repeat(64);
    await expect(synchronizeStaffSession(exchangeToken)).resolves.toBe("/backoffice");
    expect(fetchMock).toHaveBeenCalledWith("/api/staff-auth/session", expect.objectContaining({
      method: "POST",
      credentials: "same-origin",
      headers: expect.objectContaining({ "X-Duindorp-CSRF": "same-origin" }),
      body: JSON.stringify({ exchangeToken }),
    }));
  });
});
