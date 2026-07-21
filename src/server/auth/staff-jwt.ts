import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";

const STAFF_JWT_TIMEOUT_MS = 5_000;
const staffClaimsSchema = z.object({
  sub: z.string().uuid(),
  aal: z.literal("aal2"),
  role: z.literal("authenticated"),
  session_id: z.string().uuid(),
}).passthrough();

let cachedIssuer = "";
let cachedJwks: JWTVerifyGetKey | null = null;

function remoteJwks(issuer: string) {
  if (cachedJwks && cachedIssuer === issuer) return cachedJwks;
  cachedIssuer = issuer;
  cachedJwks = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`), {
    timeoutDuration: STAFF_JWT_TIMEOUT_MS,
    cooldownDuration: 30_000,
    cacheMaxAge: 10 * 60_000,
  });
  return cachedJwks;
}

export async function verifyStaffAal2AccessToken(accessToken: string) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !accessToken) return null;

  const issuer = `${env.NEXT_PUBLIC_SUPABASE_URL.replace(/\/$/, "")}/auth/v1`;
  try {
    const verified = await jwtVerify(accessToken, remoteJwks(issuer), {
      issuer,
      audience: "authenticated",
      algorithms: ["ES256"],
      clockTolerance: 5,
    });
    const claims = staffClaimsSchema.safeParse(verified.payload);
    return claims.success ? { userId: claims.data.sub } : null;
  } catch {
    return null;
  }
}
