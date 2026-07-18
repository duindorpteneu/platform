import { createHmac, randomBytes, randomInt } from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";

export const parentEmailSchema = z.object({ email: z.string().trim().email().max(320) });
export const parentCodeSchema = z.object({ email: z.string().trim().email().max(320), code: z.string().regex(/^\d{6}$/) });

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
