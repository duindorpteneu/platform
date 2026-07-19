import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomInt } from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";

export const parentEmailSchema = z.object({ email: z.string().trim().email().max(320) });
export const parentCodeSchema = z.object({ email: z.string().trim().email().max(320), code: z.string().regex(/^\d{6}$/) });
export const parentCodeInputSchema = z.object({ code: z.string().regex(/^\d{6}$/) });

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

export function generateParentCode() {
  return randomInt(100000, 1000000).toString();
}

export function generateParentSessionToken() {
  return randomBytes(32).toString("base64url");
}

export function sealParentChallengeEmail(email: string, now = Date.now()) {
  const iv = randomBytes(12);
  const key = createHash("sha256").update(pepper()).digest();
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const plaintext = Buffer.from(JSON.stringify({ email: normalizeParentEmail(email), expiresAt: now + 10 * 60 * 1000 }));
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return `${iv.toString("base64url")}.${cipher.getAuthTag().toString("base64url")}.${ciphertext.toString("base64url")}`;
}

export function openParentChallengeEmail(token: string, now = Date.now()) {
  try {
    const [ivValue, tagValue, ciphertextValue] = token.split(".");
    if (!ivValue || !tagValue || !ciphertextValue) return null;
    const key = createHash("sha256").update(pepper()).digest();
    const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(ivValue, "base64url"));
    decipher.setAuthTag(Buffer.from(tagValue, "base64url"));
    const payload = JSON.parse(Buffer.concat([decipher.update(Buffer.from(ciphertextValue, "base64url")), decipher.final()]).toString("utf8"));
    const parsed = z.object({ email: z.string().email().max(320), expiresAt: z.number().int() }).safeParse(payload);
    if (!parsed.success || parsed.data.expiresAt < now) return null;
    return normalizeParentEmail(parsed.data.email);
  } catch {
    return null;
  }
}
