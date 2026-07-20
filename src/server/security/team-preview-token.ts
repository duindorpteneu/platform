import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const common = {
  team: z.string().min(1).max(120),
  seasonId: z.string().uuid(),
  revision: z.string().regex(/^[a-f0-9]{64}$/),
  expiresAt: z.number().int().positive(),
};
const payloadSchema = z.discriminatedUnion("operation", [
  z.object({ operation: z.literal("member-status"), ...common, active: z.boolean() }).strict(),
  z.object({ operation: z.literal("order-articles"), ...common, variantIds: z.array(z.string().uuid()).min(1).max(25) }).strict(),
]);
export type TeamPreviewPayload = z.infer<typeof payloadSchema>;
type TeamPreviewInput =
  | Omit<Extract<TeamPreviewPayload, { operation: "member-status" }>, "expiresAt">
  | Omit<Extract<TeamPreviewPayload, { operation: "order-articles" }>, "expiresAt">;

function signature(encoded: string, pepper: string) {
  return createHmac("sha256", pepper).update(`team-preview:${encoded}`).digest("base64url");
}

export function createTeamPreviewToken(payload: TeamPreviewInput, pepper: string, now = Date.now()) {
  if (pepper.length < 32) throw new Error("TEAM_PREVIEW_PEPPER_MISSING");
  const normalized = payload.operation === "order-articles"
    ? { ...payload, variantIds: [...payload.variantIds].sort(), expiresAt: now + 10 * 60 * 1000 }
    : { ...payload, expiresAt: now + 10 * 60 * 1000 };
  const encoded = Buffer.from(JSON.stringify(payloadSchema.parse(normalized))).toString("base64url");
  return `${encoded}.${signature(encoded, pepper)}`;
}

export function verifyTeamPreviewToken(token: string, pepper: string, now = Date.now()) {
  const [encoded, provided, extra] = token.split(".");
  if (!encoded || !provided || extra) throw new Error("TEAM_PREVIEW_TOKEN_INVALID");
  const expected = signature(encoded, pepper);
  const left = Buffer.from(provided); const right = Buffer.from(expected);
  if (left.length !== right.length || !timingSafeEqual(left, right)) throw new Error("TEAM_PREVIEW_TOKEN_INVALID");
  let decoded: unknown;
  try { decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")); } catch { throw new Error("TEAM_PREVIEW_TOKEN_INVALID"); }
  const payload = payloadSchema.parse(decoded);
  if (payload.expiresAt < now) throw new Error("TEAM_PREVIEW_TOKEN_EXPIRED");
  return payload;
}
