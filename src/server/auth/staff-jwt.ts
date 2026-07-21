import { createLocalJWKSet, createRemoteJWKSet, jwtVerify, type JSONWebKeySet, type JWTVerifyGetKey } from "jose";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";

const STAFF_JWT_TIMEOUT_MS = 5_000;
export class StaffJwtUnavailableError extends Error {
  constructor() { super("STAFF_JWT_UNAVAILABLE"); }
}
const staffClaimsSchema = z.object({
  sub: z.string().uuid(),
  aal: z.literal("aal2"),
  role: z.literal("authenticated"),
  session_id: z.string().uuid(),
}).passthrough();

let cachedIssuer = "";
let cachedJwksSource = "";
let cachedJwks: JWTVerifyGetKey | null = null;

const jwksSchema = z.object({
  keys: z.array(z.object({
    kty: z.literal("EC"),
    crv: z.literal("P-256"),
    alg: z.literal("ES256"),
    kid: z.string().min(1),
    x: z.string().min(40),
    y: z.string().min(40),
  }).passthrough()).min(1),
}).strict();

function verificationKeySet(issuer: string, configuredJwks?: string) {
  const source = configuredJwks ?? "remote";
  if (cachedJwks && cachedIssuer === issuer && cachedJwksSource === source) return cachedJwks;
  cachedIssuer = issuer;
  cachedJwksSource = source;
  if (configuredJwks) {
    const parsed = jwksSchema.parse(JSON.parse(configuredJwks));
    cachedJwks = createLocalJWKSet(parsed as JSONWebKeySet);
  } else {
    cachedJwks = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`), {
      timeoutDuration: STAFF_JWT_TIMEOUT_MS,
      cooldownDuration: 30_000,
      cacheMaxAge: 10 * 60_000,
    });
  }
  return cachedJwks;
}

export async function verifyStaffAal2AccessToken(accessToken: string) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !accessToken) return null;

  const issuer = `${env.NEXT_PUBLIC_SUPABASE_URL.replace(/\/$/, "")}/auth/v1`;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const verified = await Promise.race([
      jwtVerify(accessToken, verificationKeySet(issuer, env.SUPABASE_JWKS), {
        issuer,
        audience: "authenticated",
        algorithms: ["ES256"],
        clockTolerance: 5,
      }),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new StaffJwtUnavailableError()), STAFF_JWT_TIMEOUT_MS);
      }),
    ]);
    const claims = staffClaimsSchema.safeParse(verified.payload);
    return claims.success ? { userId: claims.data.sub } : null;
  } catch (error) {
    if (error instanceof StaffJwtUnavailableError) throw error;
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}
