import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const payloadSchema = z.object({
  operation: z.enum(["activate", "revoke"]),
  actorId: z.string().uuid(),
  seasonId: z.string().uuid(),
  selectionDigest: z.string().regex(/^[0-9a-f]{64}$/),
  revision: z.string().regex(/^[0-9a-f]{64}$/),
  expiresAt: z.number().int().positive(),
}).strict();

export type PortalAccessPreviewPayload = z.infer<typeof payloadSchema>;

function signature(encoded: string, pepper: string) {
  return createHmac("sha256", pepper)
    .update(`portal-access-preview:${encoded}`)
    .digest("base64url");
}

export function portalAccessSelectionDigest(
  operation: PortalAccessPreviewPayload["operation"],
  seasonId: string,
  ids: readonly string[],
) {
  return createHash("sha256")
    .update(JSON.stringify({ operation, seasonId, ids: [...ids].sort() }))
    .digest("hex");
}

export function createPortalAccessPreviewToken(
  input: Omit<PortalAccessPreviewPayload, "selectionDigest" | "expiresAt"> & {
    ids: readonly string[];
  },
  pepper: string,
  now = Date.now(),
) {
  if (pepper.length < 32) throw new Error("PORTAL_ACCESS_PREVIEW_PEPPER_MISSING");
  const payload = payloadSchema.parse({
    operation: input.operation,
    actorId: input.actorId,
    seasonId: input.seasonId,
    selectionDigest: portalAccessSelectionDigest(input.operation, input.seasonId, input.ids),
    revision: input.revision,
    expiresAt: now + 10 * 60 * 1000,
  });
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${encoded}.${signature(encoded, pepper)}`;
}

export function verifyPortalAccessPreviewToken(
  token: string,
  pepper: string,
  expected: {
    operation: PortalAccessPreviewPayload["operation"];
    actorId: string;
    seasonId: string;
    ids: readonly string[];
  },
  now = Date.now(),
) {
  if (pepper.length < 32) throw new Error("PORTAL_ACCESS_PREVIEW_PEPPER_MISSING");
  const [encoded, provided, extra] = token.split(".");
  if (!encoded || !provided || extra) throw new Error("PORTAL_ACCESS_PREVIEW_TOKEN_INVALID");
  const expectedSignature = signature(encoded, pepper);
  const left = Buffer.from(provided);
  const right = Buffer.from(expectedSignature);
  if (left.length !== right.length || !timingSafeEqual(left, right)) {
    throw new Error("PORTAL_ACCESS_PREVIEW_TOKEN_INVALID");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new Error("PORTAL_ACCESS_PREVIEW_TOKEN_INVALID");
  }
  const payload = payloadSchema.safeParse(decoded);
  if (!payload.success) throw new Error("PORTAL_ACCESS_PREVIEW_TOKEN_INVALID");
  if (payload.data.expiresAt < now) throw new Error("PORTAL_ACCESS_PREVIEW_TOKEN_EXPIRED");
  const expectedDigest = portalAccessSelectionDigest(
    expected.operation,
    expected.seasonId,
    expected.ids,
  );
  if (
    payload.data.operation !== expected.operation
    || payload.data.actorId !== expected.actorId
    || payload.data.seasonId !== expected.seasonId
    || payload.data.selectionDigest !== expectedDigest
  ) {
    throw new Error("PORTAL_ACCESS_PREVIEW_TOKEN_MISMATCH");
  }
  return payload.data;
}
