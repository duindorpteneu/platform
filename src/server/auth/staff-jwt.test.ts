import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createRemoteJWKSet: vi.fn(() => vi.fn()),
  jwtVerify: vi.fn(),
}));

vi.mock("jose", () => mocks);

import { verifyStaffAal2AccessToken } from "@/server/auth/staff-jwt";

const validClaims = {
  sub: "00000000-0000-4000-8000-000000000001",
  aal: "aal2",
  role: "authenticated",
  session_id: "00000000-0000-4000-8000-000000000002",
};

describe("staff Supabase JWT verification", () => {
  beforeEach(() => {
    mocks.createRemoteJWKSet.mockClear();
    mocks.jwtVerify.mockReset();
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co";
  });

  it("accepteert alleen geverifieerde AAL2-claims van de vaste issuer", async () => {
    mocks.jwtVerify.mockResolvedValue({ payload: validClaims });

    await expect(verifyStaffAal2AccessToken("signed-token")).resolves.toEqual({ userId: validClaims.sub });
    expect(mocks.jwtVerify).toHaveBeenCalledWith("signed-token", expect.any(Function), {
      issuer: "https://project.supabase.co/auth/v1",
      audience: "authenticated",
      algorithms: ["ES256"],
      clockTolerance: 5,
    });
  });

  it.each([
    [{ ...validClaims, aal: "aal1" }],
    [{ ...validClaims, role: "anon" }],
    [{ ...validClaims, sub: "not-a-uuid" }],
  ])("weigert ongeschikte claims", async (payload) => {
    mocks.jwtVerify.mockResolvedValue({ payload });
    await expect(verifyStaffAal2AccessToken("signed-token")).resolves.toBeNull();
  });

  it("faalt gesloten bij een ongeldige handtekening, issuer, audience of verloopdatum", async () => {
    mocks.jwtVerify.mockRejectedValue(new Error("JWT verification failed"));
    await expect(verifyStaffAal2AccessToken("tampered-token")).resolves.toBeNull();
  });
});
