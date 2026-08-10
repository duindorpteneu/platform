import { z } from "zod";

const uuid = z.string().uuid();

export const MEMBER_BULK_CONTEXT_STORAGE_KEY = "duindorp.member-bulk-context.v1";
export const MEMBER_BULK_CONTEXT_TTL_MS = 10 * 60 * 1_000;

export const memberBulkContextSchema = z.object({
  version: z.literal(1),
  source: z.literal("member_overview"),
  target: z.enum(["portal_access", "email"]),
  seasonId: uuid,
  createdAt: z.string().datetime({ offset: true }),
  expiresAt: z.string().datetime({ offset: true }),
  entries: z.array(z.object({
    memberId: uuid,
    memberSeasonId: uuid,
    orderId: uuid.nullable(),
    team: z.string().trim().min(1).max(120),
  }).strict()).min(1).max(50).superRefine((entries, context) => {
    if (new Set(entries.map((entry) => entry.memberSeasonId)).size !== entries.length) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "De selectie bevat dubbele lid-seizoenen.",
      });
    }
  }),
}).strict();

export type MemberBulkContext = z.infer<typeof memberBulkContextSchema>;

export function parseFreshMemberBulkContext(
  value: string | null,
  target: MemberBulkContext["target"],
  now = Date.now(),
) {
  if (!value) return null;
  try {
    const parsed = memberBulkContextSchema.safeParse(JSON.parse(value));
    if (!parsed.success || parsed.data.target !== target) return null;
    const createdAt = Date.parse(parsed.data.createdAt);
    const expiresAt = Date.parse(parsed.data.expiresAt);
    if (
      !Number.isFinite(createdAt)
      || !Number.isFinite(expiresAt)
      || createdAt > now + 30_000
      || expiresAt <= now
      || expiresAt - createdAt > MEMBER_BULK_CONTEXT_TTL_MS
    ) {
      return null;
    }
    return parsed.data;
  } catch {
    return null;
  }
}
