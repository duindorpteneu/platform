import { z } from "zod";

const uuid = z.string().uuid();
const nonNegativeInteger = z.number().int().nonnegative();
const revisionHash = z.string().regex(/^[0-9a-f]{64}$/);

export const catalogIconTypeSchema = z.enum(["shirt", "package", "circle-dot"]);
export type CatalogIconType = z.infer<typeof catalogIconTypeSchema>;
export const catalogOrderLineStatusSchema = z.enum(["backorder", "ready_for_pickup", "picked_up", "cancelled"]);

const catalogVariantSchema = z.object({
  id: uuid,
  size: z.string().trim().min(1).max(80),
  supplierCode: z.string().trim().min(1).max(120).nullable(),
  aliases: z.array(z.string().trim().min(1).max(80)).max(25),
  active: z.boolean(),
  sortOrder: z.number().int().min(0).max(10_000),
  used: z.boolean(),
  receivedQuantity: nonNegativeInteger,
  availableQuantity: z.number().int(),
}).strict();

const catalogArticleSchema = z.object({
  id: uuid,
  name: z.string().trim().min(1).max(120),
  code: z.string().regex(/^[A-Z0-9_-]{2,24}$/),
  iconType: catalogIconTypeSchema,
  active: z.boolean(),
  sortOrder: z.number().int().min(0).max(10_000),
  seasonIds: z.array(uuid).max(100),
  variants: z.array(catalogVariantSchema).max(500),
  matchConflicts: z.array(z.object({
    key: z.string().min(1).max(120),
    variantIds: z.array(uuid).min(1).max(500),
    reason: z.enum(["ambiguous", "invalid_other", "unsafe_format"]),
  }).strict()).max(500),
}).strict();

const orderLineSchema = z.object({
  id: uuid,
  articleId: uuid,
  variantId: uuid,
  quantity: z.number().int().min(1).max(25),
  status: catalogOrderLineStatusSchema,
}).strict();

const memberOrderSchema = z.object({
  id: uuid,
  amountDueCents: nonNegativeInteger,
  paid: z.boolean(),
  lines: z.array(orderLineSchema).max(25),
}).strict();

const packageSizeChangeBaseSchema = z.object({
  requestId: uuid,
  memberId: uuid,
  memberSeasonId: uuid,
  memberName: z.string().trim().min(1).max(320),
  team: z.string().trim().min(1).max(120).nullable(),
  articleId: uuid,
  articleName: z.string().trim().min(1).max(120),
  currentVariantId: uuid,
  currentSize: z.string().trim().min(1).max(80),
  requestedAt: z.string().datetime({ offset: true }),
  revision: revisionHash,
  variants: z.array(z.object({
    id: uuid,
    label: z.string().trim().min(1).max(80),
  }).strict()).max(500),
});

const packageSizeChangeRequestSchema = z.discriminatedUnion(
  "requestedKind",
  [
    packageSizeChangeBaseSchema.extend({
      requestedKind: z.literal("variant"),
      requestedVariantId: uuid,
      requestedSize: z.string().trim().min(1).max(80),
      requestedRawValue: z.null(),
      requestedMemberNote: z.null(),
    }).strict(),
    packageSizeChangeBaseSchema.extend({
      requestedKind: z.literal("other"),
      requestedVariantId: z.null(),
      requestedSize: z.null(),
      requestedRawValue: z.literal("Anders…"),
      requestedMemberNote: z.string().trim().min(1).max(500),
    }).strict(),
  ],
);

export const catalogOrderWorkspaceSchema = z.object({
  activeSeason: z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
    defaultAmountCents: nonNegativeInteger,
  }).strict().nullable(),
  seasons: z.array(z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
    status: z.enum(["open", "archived"]),
    active: z.boolean(),
  }).strict()).max(100),
  teamOptions: z.array(z.string().min(1).max(120)).max(500),
  articles: z.array(catalogArticleSchema).max(500),
  members: z.array(z.object({
    id: uuid,
    name: z.string().trim().min(1).max(320),
    relationNumber: z.string().trim().min(1).max(120).nullable(),
    team: z.string().trim().min(1).max(120),
    order: memberOrderSchema.nullable(),
  }).strict()).max(10_000),
  packageFeatureEnabled: z.boolean(),
  packageRevisions: z.array(z.object({
    revisionId: uuid,
    name: z.string().trim().min(1).max(120),
    priceCents: nonNegativeInteger.max(10_000_000),
    currency: z.string().regex(/^[A-Z]{3}$/),
    revisionNumber: z.number().int().positive(),
    isDefault: z.boolean(),
  }).strict()).max(100),
  packageOrders: z.array(z.object({
    memberId: uuid,
    memberSeasonId: uuid,
    orderId: uuid.nullable(),
    packageRevisionId: uuid.nullable(),
    packageName: z.string().trim().min(1).max(120).nullable(),
    canSwitchPackage: z.boolean(),
    revision: revisionHash,
  }).strict()).max(10_000),
  packageSizeChangeRequests: z.array(
    packageSizeChangeRequestSchema,
  ).max(10_000),
}).strict();

function uniqueValues(values: readonly string[]) {
  return new Set(values).size === values.length;
}

function normalizeVariantMatchKey(value: string) {
  return value
    .normalize("NFKC")
    .trim()
    .replace(/\s+/gu, " ")
    .toLocaleUpperCase("nl-NL");
}

export const catalogArticleRequestSchema = z.object({
  articleId: uuid.nullable().optional(),
  name: z.string().trim().min(1).max(120),
  code: z.string().trim().toUpperCase().regex(/^[A-Z0-9_-]{2,24}$/),
  iconType: catalogIconTypeSchema,
  active: z.boolean(),
  sortOrder: z.number().int().min(0).max(10_000),
  seasonIds: z.array(uuid).min(1).max(100),
}).strict().superRefine((value, context) => {
  if (!uniqueValues(value.seasonIds)) context.addIssue({ code: z.ZodIssueCode.custom, path: ["seasonIds"], message: "Seizoenen moeten uniek zijn." });
});

export const catalogVariantRequestSchema = z.object({
  articleId: uuid,
  variantId: uuid.nullable().optional(),
  size: z.string().trim().min(1).max(80),
  supplierCode: z.preprocess(
    (value) => typeof value === "string" && value.trim() === "" ? null : value,
    z.string().trim().min(1).max(120).nullable(),
  ),
  aliases: z.array(z.string().trim().min(1).max(80)).max(25),
  active: z.boolean(),
  sortOrder: z.number().int().min(0).max(10_000),
}).strict().superRefine((value, context) => {
  const unsafeFormat = /[\p{Cf}\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u3164\uFE00-\uFE0F\uFFA0]/u;
  const sizeKey = normalizeVariantMatchKey(value.size);
  const codeKey = value.supplierCode ? normalizeVariantMatchKey(value.supplierCode) : null;
  const normalized = value.aliases.map(normalizeVariantMatchKey);
  if (unsafeFormat.test(value.size) || (value.supplierCode && unsafeFormat.test(value.supplierCode)) || value.aliases.some((alias) => unsafeFormat.test(alias))) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["aliases"], message: "Onzichtbare of bidi-opmaaktekens zijn niet toegestaan." });
  }
  if (/^ANDERS(?:[ .…]*)$/u.test(sizeKey) || (codeKey && /^ANDERS(?:[ .…]*)$/u.test(codeKey))) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["size"], message: "Anders is een conflict en geen variant." });
  }
  if (!uniqueValues(normalized)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["aliases"], message: "Maataliassen moeten na normalisatie uniek zijn." });
  }
  if (normalized.some((alias) => /^ANDERS(?:[ .…]*)$/u.test(alias))) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["aliases"], message: "Anders is een conflict en geen maatalias." });
  }
}).transform((value) => {
  const ownMatchKeys = new Set([
    normalizeVariantMatchKey(value.size),
    ...(value.supplierCode ? [normalizeVariantMatchKey(value.supplierCode)] : []),
  ]);
  return {
    ...value,
    aliases: value.aliases.filter(
      (alias) => !ownMatchKeys.has(normalizeVariantMatchKey(alias)),
    ),
  };
});

export const saveMemberOrderRequestSchema = z.object({
  memberId: uuid,
  seasonId: uuid,
  amountDueCents: z.number().int().min(0).max(10_000_000),
  lines: z.array(z.object({
    variantId: uuid,
    quantity: z.number().int().min(1).max(25),
  }).strict()).min(1).max(25),
}).strict().superRefine((value, context) => {
  const variantIds = value.lines.map((line) => line.variantId);
  if (!uniqueValues(variantIds)) context.addIssue({ code: z.ZodIssueCode.custom, path: ["lines"], message: "Een variant mag maar één keer voorkomen." });
});

export const catalogMutationResponseSchema = z.string().uuid();
export const bulkArticleSeasonRequestSchema = z.object({
  seasonId: uuid,
  articleIds: z.array(uuid).min(1).max(500),
  linked: z.boolean(),
}).strict().superRefine((value, context) => {
  if (!uniqueValues(value.articleIds)) context.addIssue({ code: z.ZodIssueCode.custom, path: ["articleIds"], message: "Artikelen moeten uniek zijn." });
});
export const bulkArticleSeasonResponseSchema = z.object({
  seasonId: uuid,
  linked: z.boolean(),
  requestedCount: z.number().int().min(1).max(500),
  changedCount: z.number().int().min(0).max(500),
}).strict();
export const saveMemberOrderResponseSchema = z.object({
  orderId: uuid,
  amountDueCents: nonNegativeInteger,
  lineCount: z.number().int().min(1).max(25),
}).strict();

export const teamOrderArticlesRequestSchema = z.object({
  team: z.string().trim().min(1).max(120),
  variantIds: z.array(uuid).min(1).max(25),
  previewToken: z.string().min(64).max(4_000).optional(),
  commit: z.boolean(),
}).strict().superRefine((value, context) => {
  if (!uniqueValues(value.variantIds)) context.addIssue({ code: z.ZodIssueCode.custom, path: ["variantIds"], message: "Varianten moeten uniek zijn." });
  if (value.commit && !value.previewToken) context.addIssue({ code: z.ZodIssueCode.custom, path: ["previewToken"], message: "Controleer de toewijzing opnieuw." });
  if (!value.commit && value.previewToken) context.addIssue({ code: z.ZodIssueCode.custom, path: ["previewToken"], message: "Een previewtoken hoort niet bij een previewaanvraag." });
});

export const teamOrderArticlesResponseSchema = z.object({
  seasonId: uuid,
  team: z.string().min(1).max(120),
  selectedVariantCount: z.number().int().min(1).max(25),
  totalMembers: nonNegativeInteger,
  activeMembers: nonNegativeInteger,
  inactiveMembersSkipped: nonNegativeInteger,
  paidOrdersSkipped: nonNegativeInteger,
  ordersCreated: nonNegativeInteger,
  ordersExtended: nonNegativeInteger,
  unchangedMembers: nonNegativeInteger,
  linesAdded: nonNegativeInteger,
  committed: z.boolean(),
  previewToken: z.string().min(64).max(4_000).optional(),
}).strict();

export function parseEuroAmountToCents(value: string): number | null {
  const normalized = value.trim();
  if (!/^\d{1,7}(?:[,.]\d{1,2})?$/.test(normalized)) return null;
  const [euros, decimals = ""] = normalized.replace(",", ".").split(".");
  const cents = Number(euros) * 100 + Number(decimals.padEnd(2, "0"));
  return Number.isSafeInteger(cents) && cents <= 10_000_000 ? cents : null;
}

export function formatCentsForEuroInput(cents: number) {
  if (!Number.isInteger(cents) || cents < 0) throw new Error("INVALID_CENTS");
  return `${Math.floor(cents / 100)},${String(cents % 100).padStart(2, "0")}`;
}

export type CatalogOrderWorkspace = z.infer<typeof catalogOrderWorkspaceSchema>;
export type CatalogArticleRequest = z.infer<typeof catalogArticleRequestSchema>;
export type CatalogVariantRequest = z.infer<typeof catalogVariantRequestSchema>;
export type BulkArticleSeasonRequest = z.infer<typeof bulkArticleSeasonRequestSchema>;
export type SaveMemberOrderRequest = z.infer<typeof saveMemberOrderRequestSchema>;
export type TeamOrderArticlesResponse = z.infer<typeof teamOrderArticlesResponseSchema>;
