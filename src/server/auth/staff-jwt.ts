import { createPublicKey, verify as verifySignature, type JsonWebKey } from "node:crypto";
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";

const STAFF_JWT_TIMEOUT_MS = 5_000;
const CLOCK_TOLERANCE_SECONDS = 5;
const BASE64URL = /^[A-Za-z0-9_-]+$/;

export class StaffJwtUnavailableError extends Error {
  constructor() { super("STAFF_JWT_UNAVAILABLE"); }
}

const staffClaimsSchema = z.object({
  sub: z.string().uuid(),
  aal: z.literal("aal2"),
  role: z.literal("authenticated"),
  session_id: z.string().uuid(),
  iss: z.string().url(),
  aud: z.union([z.string(), z.array(z.string()).min(1)]),
  exp: z.number().int(),
  nbf: z.number().int().optional(),
  iat: z.number().int().optional(),
}).passthrough();

const jwtHeaderSchema = z.object({
  alg: z.literal("ES256"),
  kid: z.string().min(1),
  typ: z.string().optional(),
}).passthrough();

const jwkSchema = z.object({
  kty: z.literal("EC"),
  crv: z.literal("P-256"),
  alg: z.literal("ES256"),
  kid: z.string().min(1),
  use: z.string().optional(),
  x: z.string().regex(BASE64URL).min(40),
  y: z.string().regex(BASE64URL).min(40),
}).passthrough();

const jwksSchema = z.object({
  keys: z.array(jwkSchema).min(1),
}).strict().superRefine((value, context) => {
  const seen = new Set<string>();
  for (const key of value.keys) {
    if (seen.has(key.kid)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["keys"], message: "JWK-kids moeten uniek zijn." });
    }
    seen.add(key.kid);
  }
});

let cachedIssuer = "";
let cachedRemoteJwks: JWTVerifyGetKey | null = null;

function decodeJsonSegment(segment: string, maximumBytes: number) {
  if (!segment || !BASE64URL.test(segment)) return null;
  const bytes = Buffer.from(segment, "base64url");
  if (bytes.length === 0 || bytes.length > maximumBytes) return null;
  try {
    return JSON.parse(bytes.toString("utf8")) as unknown;
  } catch {
    return null;
  }
}

function hasExpectedAudience(audience: string | string[]) {
  return typeof audience === "string"
    ? audience === "authenticated"
    : audience.length === 1 && audience[0] === "authenticated";
}

function claimsAreCurrent(claims: z.infer<typeof staffClaimsSchema>, issuer: string) {
  const now = Math.floor(Date.now() / 1_000);
  return claims.iss === issuer
    && hasExpectedAudience(claims.aud)
    && claims.exp > now - CLOCK_TOLERANCE_SECONDS
    && (claims.nbf === undefined || claims.nbf <= now + CLOCK_TOLERANCE_SECONDS)
    && (claims.iat === undefined || claims.iat <= now + CLOCK_TOLERANCE_SECONDS);
}

function verifyWithConfiguredJwks(accessToken: string, configuredJwks: string, issuer: string) {
  const segments = accessToken.split(".");
  if (segments.length !== 3) return null;
  const [encodedHeader, encodedPayload, encodedSignature] = segments as [string, string, string];
  const header = jwtHeaderSchema.safeParse(decodeJsonSegment(encodedHeader, 2_048));
  const claims = staffClaimsSchema.safeParse(decodeJsonSegment(encodedPayload, 12_288));
  if (!header.success || !claims.success || !claimsAreCurrent(claims.data, issuer)) return null;

  const jwks = jwksSchema.safeParse(JSON.parse(configuredJwks));
  if (!jwks.success) return null;
  const jwk = jwks.data.keys.find((candidate) => candidate.kid === header.data.kid);
  if (!jwk || !BASE64URL.test(encodedSignature)) return null;
  const signature = Buffer.from(encodedSignature, "base64url");
  if (signature.length !== 64) return null;

  const key = createPublicKey({ key: jwk as JsonWebKey, format: "jwk" });
  const valid = verifySignature(
    "sha256",
    Buffer.from(`${encodedHeader}.${encodedPayload}`, "ascii"),
    { key, dsaEncoding: "ieee-p1363" },
    signature,
  );
  return valid ? { userId: claims.data.sub } : null;
}

function remoteKeySet(issuer: string) {
  if (cachedRemoteJwks && cachedIssuer === issuer) return cachedRemoteJwks;
  cachedIssuer = issuer;
  cachedRemoteJwks = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`), {
    timeoutDuration: STAFF_JWT_TIMEOUT_MS,
    cooldownDuration: 30_000,
    cacheMaxAge: 10 * 60_000,
  });
  return cachedRemoteJwks;
}

async function verifyWithRemoteJwks(accessToken: string, issuer: string) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new StaffJwtUnavailableError()), STAFF_JWT_TIMEOUT_MS);
    });
    const verification = Promise.resolve().then(() => jwtVerify(accessToken, remoteKeySet(issuer), {
      issuer,
      audience: "authenticated",
      algorithms: ["ES256"],
      clockTolerance: CLOCK_TOLERANCE_SECONDS,
    }));
    const verified = await Promise.race([verification, timeout]);
    const claims = staffClaimsSchema.safeParse(verified.payload);
    return claims.success && claimsAreCurrent(claims.data, issuer) ? { userId: claims.data.sub } : null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export async function verifyStaffAal2AccessToken(accessToken: string) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !accessToken) return null;
  const issuer = `${env.NEXT_PUBLIC_SUPABASE_URL.replace(/\/$/, "")}/auth/v1`;

  try {
    return env.SUPABASE_JWKS
      ? verifyWithConfiguredJwks(accessToken, env.SUPABASE_JWKS, issuer)
      : await verifyWithRemoteJwks(accessToken, issuer);
  } catch (error) {
    if (error instanceof StaffJwtUnavailableError) throw error;
    return null;
  }
}
