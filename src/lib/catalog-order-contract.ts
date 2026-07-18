import { z } from "zod";

const uuid = z.string().uuid();
const nonNegativeInteger = z.number().int().nonnegative();

export const catalogIconTypeSchema = z.enum(["shirt", "package", "circle-dot"]);
export const catalogOrderLineStatusSchema = z.enum(["backorder", "ready_for_pickup", "picked_up", "cancelled"]);

const catalogVariantSchema = z.object({
  id: uuid,
  size: z.string().trim().min(1).max(80),
  supplierCode: z.string().trim().min(1).max(120).nullable(),
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

export const catalogOrderWorkspaceSchema = z.object({
  activeSeason: z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
    defaultAmountCents: nonNegativeInteger,
  }).strict().nullable(),
  articles: z.array(catalogArticleSchema).max(500),
  members: z.array(z.object({
    id: uuid,
    name: z.string().trim().min(1).max(320),
    relationNumber: z.string().trim().min(1).max(80),
    team: z.string().trim().min(1).max(120),
    order: memberOrderSchema.nullable(),
  }).strict()).max(10_000),
}).strict();

function uniqueValues(values: readonly string[]) {
  return new Set(values).size === values.length;
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
  active: z.boolean(),
  sortOrder: z.number().int().min(0).max(10_000),
}).strict();

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
export const saveMemberOrderResponseSchema = z.object({
  orderId: uuid,
  amountDueCents: nonNegativeInteger,
  lineCount: z.number().int().min(1).max(25),
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
export type SaveMemberOrderRequest = z.infer<typeof saveMemberOrderRequestSchema>;

