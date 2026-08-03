import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  cookies: vi.fn(),
  fetchContext: vi.fn(),
  getCookie: vi.fn(),
}));

vi.mock("next/headers", () => ({ cookies: mocks.cookies }));
vi.mock("@/server/auth/staff-context", () => ({
  fetchStaffContext: mocks.fetchContext,
  STAFF_SESSION_COOKIE: "duindorp_staff_session",
}));

import { requireStaffSessionBinding } from "@/server/auth/staff";

describe("requireStaffSessionBinding", () => {
  beforeEach(() => {
    mocks.getCookie.mockReset().mockReturnValue({ value: "opaque-session" });
    mocks.cookies.mockReset().mockResolvedValue({ get: mocks.getCookie });
    mocks.fetchContext.mockReset().mockResolvedValue({
      userId: "10000000-0000-4000-8000-000000000001",
      role: "uitgifte",
      displayName: "Scanner",
      aal2: true,
    });
  });

  it("bindt de appcontext aan uitsluitend de hash van de opaque cookie", async () => {
    const result = await requireStaffSessionBinding(["uitgifte"]);
    expect(mocks.getCookie).toHaveBeenCalledWith(
      "duindorp_staff_session",
    );
    expect(mocks.fetchContext).toHaveBeenCalledWith("opaque-session");
    expect(result.sessionTokenHash).toBe(
      createHash("sha256").update("opaque-session").digest("hex"),
    );
    expect(JSON.stringify(result)).not.toContain("opaque-session");
  });

  it("weigert een ontbrekende of ingetrokken sessie", async () => {
    mocks.getCookie.mockReturnValueOnce(undefined);
    await expect(
      requireStaffSessionBinding(["uitgifte"]),
    ).rejects.toThrow("STAFF_AUTHORIZATION_REQUIRED");
    expect(mocks.fetchContext).not.toHaveBeenCalled();

    mocks.fetchContext.mockResolvedValueOnce(null);
    await expect(
      requireStaffSessionBinding(["uitgifte"]),
    ).rejects.toThrow("STAFF_AUTHORIZATION_REQUIRED");
  });

  it("weigert een geldige sessie met een andere rol", async () => {
    await expect(
      requireStaffSessionBinding(["beheerder"]),
    ).rejects.toThrow("STAFF_AUTHORIZATION_REQUIRED");
  });
});
