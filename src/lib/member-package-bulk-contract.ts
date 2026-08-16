import { z } from "zod";

const uuid = z.string().uuid();

export const memberPackageBulkOptionsSchema = z.object({
  enabled: z.boolean(),
  seasonId: uuid.nullable(),
  packages: z.array(z.object({
    revisionId: uuid,
    name: z.string().trim().min(1).max(120),
    priceCents: z.number().int().nonnegative().max(10_000_000),
    currency: z.literal("EUR"),
    revisionNumber: z.number().int().positive(),
    default: z.boolean(),
    itemCount: z.number().int().min(1).max(25),
  }).strict()).max(100),
}).strict();

export const memberPackageBulkRequestSchema = z.object({
  action: z.enum(["assign", "remove"]),
  scope: z.enum(["selected", "all_active"]),
  memberSeasonIds: z.array(uuid).max(50),
  packageRevisionId: uuid.nullable(),
  reason: z.string().trim().min(3).max(500),
  requestId: uuid,
  commit: z.boolean(),
  previewToken: z.string().min(1).max(8_000).optional(),
}).strict().superRefine((value, context) => {
  if (new Set(value.memberSeasonIds).size !== value.memberSeasonIds.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["memberSeasonIds"], message: "Lid-seizoenen moeten uniek zijn." });
  }
  if ((value.scope === "selected") !== (value.memberSeasonIds.length > 0)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["memberSeasonIds"], message: "De selectie past niet bij de gekozen scope." });
  }
  if ((value.action === "assign") !== (value.packageRevisionId !== null)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["packageRevisionId"], message: "Toewijzen vereist één pakket; verwijderen niet." });
  }
  if (value.commit !== Boolean(value.previewToken)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["previewToken"], message: "Uitvoeren vereist een geldige voorcontrole." });
  }
});

export const memberPackageBulkResponseSchema = z.object({
  action: z.enum(["assign", "remove"]),
  scope: z.enum(["selected", "all_active"]),
  seasonId: uuid,
  packageRevisionId: uuid.nullable(),
  requestedCount: z.number().int().nonnegative(),
  matchedCount: z.number().int().nonnegative(),
  eligibleCount: z.number().int().nonnegative(),
  unchangedCount: z.number().int().nonnegative(),
  blockedCount: z.number().int().nonnegative(),
  inactiveOrInvalidCount: z.number().int().nonnegative(),
  linkedSizeCount: z.number().int().nonnegative(),
  missingSizeCount: z.number().int().nonnegative(),
  committed: z.boolean(),
  changedCount: z.number().int().nonnegative().optional(),
  reused: z.boolean().optional(),
  previewToken: z.string().min(1).max(8_000).optional(),
}).strict().superRefine((value, context) => {
  if (value.matchedCount !== value.eligibleCount + value.unchangedCount + value.blockedCount) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "De preflightaantallen sluiten niet aan." });
  }
  if (!value.committed && !value.previewToken) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["previewToken"], message: "Een voorcontrole vereist een token." });
  }
  if (value.committed && value.changedCount === undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["changedCount"], message: "Een uitgevoerde actie vereist een resultaat." });
  }
});

export type MemberPackageBulkOptions = z.infer<typeof memberPackageBulkOptionsSchema>;
export type MemberPackageBulkResponse = z.infer<typeof memberPackageBulkResponseSchema>;
