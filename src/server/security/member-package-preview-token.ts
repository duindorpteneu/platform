import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const payloadSchema = z.object({
  action: z.enum(["assign", "remove"]),
  scope: z.enum(["selected", "all_active"]),
  memberSeasonIds: z.array(z.string().uuid()).max(50),
  packageRevisionId: z.string().uuid().nullable(),
  reason: z.string().trim().min(3).max(500),
  seasonId: z.string().uuid(),
  revision: z.string().regex(/^[0-9a-f]{64}$/),
  expiresAt: z.number().int().positive(),
}).strict();

type PreviewInput = Omit<z.infer<typeof payloadSchema>, "expiresAt">;

function signature(encoded: string, pepper: string) {
  return createHmac("sha256", pepper)
    .update(`member-package-preview:${encoded}`)
    .digest("base64url");
}

export function createMemberPackagePreviewToken(input: PreviewInput, pepper: string, now = Date.now()) {
  if (pepper.length < 32) throw new Error("MEMBER_PACKAGE_PREVIEW_PEPPER_MISSING");
  const payload = payloadSchema.parse({
    ...input,
    memberSeasonIds: [...input.memberSeasonIds].sort(),
    expiresAt: now + 10 * 60 * 1_000,
  });
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${encoded}.${signature(encoded, pepper)}`;
}

export function verifyMemberPackagePreviewToken(token: string, pepper: string, now = Date.now()) {
  const [encoded, provided, extra] = token.split(".");
  if (!encoded || !provided || extra) throw new Error("MEMBER_PACKAGE_PREVIEW_TOKEN_INVALID");
  const expected = signature(encoded, pepper);
  const left = Buffer.from(provided);
  const right = Buffer.from(expected);
  if (left.length !== right.length || !timingSafeEqual(left, right)) {
    throw new Error("MEMBER_PACKAGE_PREVIEW_TOKEN_INVALID");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new Error("MEMBER_PACKAGE_PREVIEW_TOKEN_INVALID");
  }
  const payload = payloadSchema.parse(decoded);
  if (payload.expiresAt < now) throw new Error("MEMBER_PACKAGE_PREVIEW_TOKEN_EXPIRED");
  return payload;
}
