import { generateKeyPairSync, sign } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createRemoteJWKSet: vi.fn(() => vi.fn()),
  jwtVerify: vi.fn(),
}));

vi.mock("jose", () => mocks);

import { StaffJwtUnavailableError, verifyStaffAal2AccessToken } from "@/server/auth/staff-jwt";

const issuer = "https://project.supabase.co/auth/v1";
const validClaims = {
  sub: "00000000-0000-4000-8000-000000000001",
  aal: "aal2",
  role: "authenticated",
  session_id: "00000000-0000-4000-8000-000000000002",
  iss: issuer,
  aud: "authenticated",
  exp: Math.floor(Date.now() / 1_000) + 3_600,
  iat: Math.floor(Date.now() / 1_000),
};

const keyPair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const publicJwk = keyPair.publicKey.export({ format: "jwk" });
const runtimeJwks = JSON.stringify({ keys: [{
  ...publicJwk,
  alg: "ES256",
  kid: "runtime-key",
  use: "sig",
}] });

function signedToken(payload: Record<string, unknown> = validClaims, header: Record<string, unknown> = {}) {
  const encodedHeader = Buffer.from(JSON.stringify({ alg: "ES256", typ: "JWT", kid: "runtime-key", ...header })).toString("base64url");
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = sign(
    "sha256",
    Buffer.from(`${encodedHeader}.${encodedPayload}`, "ascii"),
    { key: keyPair.privateKey, dsaEncoding: "ieee-p1363" },
  ).toString("base64url");
  return `${encodedHeader}.${encodedPayload}.${signature}`;
}

describe("staff Supabase JWT verification", () => {
  beforeEach(() => {
    mocks.createRemoteJWKSet.mockClear();
    mocks.jwtVerify.mockReset();
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://project.supabase.co";
    process.env.SUPABASE_JWKS = runtimeJwks;
  });

  it("verifieert de geconfigureerde ES256-key lokaal via Node/OpenSSL zonder jose of outbound request", async () => {
    await expect(verifyStaffAal2AccessToken(signedToken())).resolves.toEqual({ userId: validClaims.sub });
    expect(mocks.createRemoteJWKSet).not.toHaveBeenCalled();
    expect(mocks.jwtVerify).not.toHaveBeenCalled();
  });

  it.each([
    [{ ...validClaims, aal: "aal1" }],
    [{ ...validClaims, role: "anon" }],
    [{ ...validClaims, sub: "not-a-uuid" }],
    [{ ...validClaims, iss: "https://attacker.example/auth/v1" }],
    [{ ...validClaims, aud: "anon" }],
    [{ ...validClaims, exp: Math.floor(Date.now() / 1_000) - 60 }],
  ])("weigert ongeschikte of verlopen claims", async (payload) => {
    await expect(verifyStaffAal2AccessToken(signedToken(payload))).resolves.toBeNull();
  });

  it("weigert een gemanipuleerde payload, handtekening of algoritmekop", async () => {
    const token = signedToken();
    const [header, payload, signature] = token.split(".");
    const tamperedPayload = Buffer.from(JSON.stringify({ ...validClaims, sub: "00000000-0000-4000-8000-000000000003" })).toString("base64url");
    await expect(verifyStaffAal2AccessToken(`${header}.${tamperedPayload}.${signature}`)).resolves.toBeNull();
    await expect(verifyStaffAal2AccessToken(`${header}.${payload}.${"A".repeat(86)}`)).resolves.toBeNull();
    await expect(verifyStaffAal2AccessToken(signedToken(validClaims, { alg: "none" }))).resolves.toBeNull();
  });

  it("behoudt een begrensde remote-JWKS fallback voor lokale ontwikkeling", async () => {
    delete process.env.SUPABASE_JWKS;
    mocks.jwtVerify.mockResolvedValue({ payload: validClaims });

    await expect(verifyStaffAal2AccessToken("signed-token")).resolves.toEqual({ userId: validClaims.sub });
    expect(mocks.createRemoteJWKSet).toHaveBeenCalledOnce();
  });

  it("breekt een vastgelopen remote verifier hard af", async () => {
    delete process.env.SUPABASE_JWKS;
    vi.useFakeTimers();
    mocks.jwtVerify.mockReturnValue(new Promise(() => undefined));
    const verification = verifyStaffAal2AccessToken("signed-token");
    const rejected = expect(verification).rejects.toBeInstanceOf(StaffJwtUnavailableError);
    await vi.advanceTimersByTimeAsync(5_001);
    await rejected;
    vi.useRealTimers();
  });
});
