import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveStaffLandingPath, resolveStaffLandingPathWithRetry } from "@/lib/staff-session";

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
});
