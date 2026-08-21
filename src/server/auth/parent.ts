import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";

const uuidSchema = z.string().uuid();
const timestampSchema = z.string().datetime({ offset: true });

// Keep the application-supplied expiry strictly inside the database's
// 30-day upper bound. This absorbs ordinary app/database clock skew without
// extending the canonical parent-session lifetime.
export const PARENT_SESSION_MAX_AGE_SECONDS =
  30 * 24 * 60 * 60 - 5 * 60;

export function parentSessionExpiresAt(now = Date.now()) {
  return new Date(now + PARENT_SESSION_MAX_AGE_SECONDS * 1_000).toISOString();
}

export const parentEmailSchema = z.object({
  email: z.string().trim().email().max(320),
});
export const parentOtpRequestSchema = z.union([
  parentEmailSchema.strict(),
  z.object({ resend: z.literal(true), forceNew: z.boolean().optional() }).strict(),
]);
export const parentCodeSchema = z.object({
  email: z.string().trim().email().max(320),
  code: z.string().regex(/^\d{6}$/u),
});
export const parentCodeInputSchema = z.object({
  code: z.string().regex(/^\d{6}$/u),
}).strict();
export const parentDirectCredentialInputSchema = z.object({
  credential: z.string().trim().length(83),
}).strict();

const parentChallengeContextSchema = z.object({
  version: z.literal(3),
  email: z.string().email().max(320),
  challengeId: uuidSchema,
  expiresAt: timestampSchema,
  cooldownUntil: timestampSchema,
}).strict();

export type ParentChallengeContext = z.infer<
  typeof parentChallengeContextSchema
>;

export function normalizeParentEmail(email: string) {
  return email.trim().toLowerCase();
}

function pepper() {
  const value = getServerEnv().PARENT_TOKEN_PEPPER;
  if (!value) throw new Error("PARENT_TOKEN_PEPPER_MISSING");
  return value;
}

export function hashParentSecret(value: string) {
  return createHmac("sha256", pepper()).update(value).digest("hex");
}

function uuidBytes(challengeId: string) {
  const parsed = uuidSchema.parse(challengeId).replaceAll("-", "");
  return Buffer.from(parsed, "hex");
}

function deriveChallengeBlock(
  domain: "parent-otp-code:v3" | "parent-login-link:v1",
  challengeId: string,
  counter: number,
) {
  const counterBytes = Buffer.allocUnsafe(4);
  counterBytes.writeUInt32BE(counter);
  return createHmac("sha256", pepper())
    .update(domain, "utf8")
    .update(Buffer.from([0]))
    .update(uuidBytes(challengeId))
    .update(Buffer.from([0]))
    .update(counterBytes)
    .digest();
}

/** Derives a stable, unbiased code in the existing 100000..999999 range. */
export function deriveParentCode(challengeId: string) {
  const range = 900_000;
  const uint32Range = 0x1_0000_0000;
  const rejectionLimit = Math.floor(uint32Range / range) * range;
  for (let counter = 0; counter <= 0xffff_ffff; counter += 1) {
    const block = deriveChallengeBlock(
      "parent-otp-code:v3",
      challengeId,
      counter,
    );
    for (let offset = 0; offset <= block.length - 4; offset += 4) {
      const candidate = block.readUInt32BE(offset);
      if (candidate < rejectionLimit) {
        return String(100_000 + (candidate % range));
      }
    }
  }
  throw new Error("PARENT_OTP_DERIVATION_FAILED");
}

function deriveParentDirectProof(challengeId: string) {
  return deriveChallengeBlock(
    "parent-login-link:v1",
    challengeId,
    0,
  ).toString("base64url");
}

export function deriveParentDirectCredential(challengeId: string) {
  return `v1.${uuidSchema.parse(challengeId)}.${deriveParentDirectProof(challengeId)}`;
}

export function verifyParentDirectCredential(value: string) {
  const parsed = parentDirectCredentialInputSchema.safeParse({
    credential: value,
  });
  if (!parsed.success) return null;
  const [version, challengeId, suppliedProof, extra] =
    parsed.data.credential.split(".");
  if (version !== "v1" || extra !== undefined || !challengeId || !suppliedProof) {
    return null;
  }
  const parsedChallengeId = uuidSchema.safeParse(challengeId);
  if (!parsedChallengeId.success || !/^[A-Za-z0-9_-]{43}$/u.test(suppliedProof)) {
    return null;
  }
  const expected = Buffer.from(
    deriveParentDirectProof(parsedChallengeId.data),
    "base64url",
  );
  const supplied = Buffer.from(suppliedProof, "base64url");
  const canonical = supplied.toString("base64url") === suppliedProof;
  return canonical
    && supplied.length === expected.length
    && timingSafeEqual(supplied, expected)
    ? parsedChallengeId.data
    : null;
}

export function generateParentChallengeId() {
  return randomUUID();
}

export function generateParentSessionToken() {
  return randomBytes(32).toString("base64url");
}

export function maskParentEmail(email: string) {
  const normalized = normalizeParentEmail(email);
  const separator = normalized.lastIndexOf("@");
  if (separator <= 0) return "***";
  const local = normalized.slice(0, separator);
  const domain = normalized.slice(separator + 1);
  return `${local.slice(0, 1)}${"*".repeat(Math.min(Math.max(local.length - 1, 3), 8))}@${domain}`;
}

function challengeCipherKey() {
  return createHash("sha256")
    .update("parent-challenge-context:v3\0", "utf8")
    .update(pepper())
    .digest();
}

export function sealParentChallengeContext(context: ParentChallengeContext) {
  const parsed = parentChallengeContextSchema.parse({
    ...context,
    email: normalizeParentEmail(context.email),
  });
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", challengeCipherKey(), iv);
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(JSON.stringify(parsed))),
    cipher.final(),
  ]);
  return [
    iv.toString("base64url"),
    cipher.getAuthTag().toString("base64url"),
    ciphertext.toString("base64url"),
  ].join(".");
}

export function openParentChallengeContext(token: string, now = Date.now()) {
  try {
    const [ivValue, tagValue, ciphertextValue, extra] = token.split(".");
    if (!ivValue || !tagValue || !ciphertextValue || extra !== undefined) {
      return null;
    }
    const decipher = createDecipheriv(
      "aes-256-gcm",
      challengeCipherKey(),
      Buffer.from(ivValue, "base64url"),
    );
    decipher.setAuthTag(Buffer.from(tagValue, "base64url"));
    const payload = JSON.parse(Buffer.concat([
      decipher.update(Buffer.from(ciphertextValue, "base64url")),
      decipher.final(),
    ]).toString("utf8"));
    const parsed = parentChallengeContextSchema.safeParse(payload);
    if (!parsed.success || Date.parse(parsed.data.expiresAt) <= now) return null;
    return parsed.data;
  } catch {
    return null;
  }
}

export function createNeutralParentChallengeContext(
  email: string,
  now = Date.now(),
): ParentChallengeContext {
  return {
    version: 3,
    email: normalizeParentEmail(email),
    challengeId: generateParentChallengeId(),
    expiresAt: new Date(now + 10 * 60 * 1_000).toISOString(),
    cooldownUntil: new Date(now + 90 * 1_000).toISOString(),
  };
}
