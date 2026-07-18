import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const payloadSchema = z.object({
  templateKey: z.string().min(1).max(80),
  orderIds: z.array(z.string().uuid()).min(1).max(2000),
  batchKey: z.string().uuid(),
  expiresAt: z.number().int().positive(),
}).strict();

function signature(encoded: string, pepper: string) {
  return createHmac("sha256", pepper).update(`email-preview:${encoded}`).digest("base64url");
}

export function createEmailPreviewToken(templateKey: string, orderIds: string[], pepper: string, now = Date.now()) {
  if (pepper.length < 32) throw new Error("PARENT_TOKEN_PEPPER_MISSING");
  const payload = payloadSchema.parse({ templateKey, orderIds: [...new Set(orderIds)].sort(), batchKey: randomUUID(), expiresAt: now + 10 * 60 * 1000 });
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${encoded}.${signature(encoded, pepper)}`;
}

export function verifyEmailPreviewToken(token: string, pepper: string, now = Date.now()) {
  const [encoded, provided, extra] = token.split(".");
  if (!encoded || !provided || extra) throw new Error("EMAIL_PREVIEW_TOKEN_INVALID");
  const expected = signature(encoded, pepper);
  const left = Buffer.from(provided); const right = Buffer.from(expected);
  if (left.length !== right.length || !timingSafeEqual(left, right)) throw new Error("EMAIL_PREVIEW_TOKEN_INVALID");
  let decoded: unknown;
  try { decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")); } catch { throw new Error("EMAIL_PREVIEW_TOKEN_INVALID"); }
  const payload = payloadSchema.parse(decoded);
  if (payload.expiresAt < now) throw new Error("EMAIL_PREVIEW_TOKEN_EXPIRED");
  return payload;
}
