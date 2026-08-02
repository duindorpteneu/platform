import { z } from "zod";

const uuid = z.string().uuid();
const currency = z.literal("EUR");
const contentHash = z.string().regex(/^[0-9a-f]{64}$/);

const packageItemSchema = z.object({
  id: uuid,
  articleId: uuid,
  quantity: z.number().int().min(1).max(25),
  productName: z.string().trim().min(1).max(120),
  productCode: z.string().trim().min(2).max(24),
  sortOrder: z.number().int().min(0).max(10_000),
}).strict();

const packageRevisionSchema = z.object({
  id: uuid,
  revisionNumber: z.number().int().positive(),
  name: z.string().trim().min(1).max(120),
  description: z.string().max(2_000),
  priceCents: z.number().int().min(0).max(10_000_000),
  currency,
  status: z.enum(["draft", "published", "archived"]),
  active: z.boolean(),
  default: z.boolean(),
  publishedAt: z.string().datetime({ offset: true }).nullable(),
  contentHash,
  items: z.array(packageItemSchema).max(25),
}).strict();

export const packageWorkspaceSchema = z.object({
  activeSeason: z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
  }).strict().nullable(),
  seasons: z.array(z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
    status: z.enum(["open", "archived"]),
    active: z.boolean(),
  }).strict()).max(100),
  articles: z.array(z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
    code: z.string().trim().min(2).max(24),
    active: z.boolean(),
    seasonIds: z.array(uuid).max(100),
    sizes: z.array(z.object({
      id: uuid,
      label: z.string().trim().min(1).max(80),
      active: z.boolean(),
    }).strict()).max(500),
  }).strict()).max(500),
  templates: z.array(z.object({
    id: uuid,
    seasonId: uuid,
    seasonName: z.string().trim().min(1).max(120),
    key: z.string().regex(/^[a-z0-9][a-z0-9_-]{1,63}$/),
    revisions: z.array(packageRevisionSchema).min(1).max(500),
  }).strict()).max(500),
}).strict();

const packageDraftItemRequestSchema = z.object({
  articleId: uuid,
  quantity: z.number().int().min(1).max(25),
  sortOrder: z.number().int().min(0).max(10_000),
}).strict();

export const packageDraftRequestSchema = z.object({
  templateId: uuid.nullable(),
  revisionId: uuid.nullable(),
  seasonId: uuid,
  key: z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9_-]{1,63}$/),
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(2_000),
  priceCents: z.number().int().min(0).max(10_000_000),
  items: z.array(packageDraftItemRequestSchema).min(1).max(25),
  expectedHash: contentHash.nullable(),
}).strict().superRefine((value, context) => {
  if (Boolean(value.templateId) !== Boolean(value.revisionId)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["revisionId"],
      message: "Template en revisie moeten samen worden opgegeven.",
    });
  }
  if (Boolean(value.templateId) !== Boolean(value.expectedHash)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["expectedHash"],
      message: "Een bestaande draft vereist de verwachte inhoudsversie.",
    });
  }
  const articleIds = value.items.map((item) => item.articleId);
  if (new Set(articleIds).size !== articleIds.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["items"],
      message: "Een product mag maar één keer in een pakket staan.",
    });
  }
});

export const packageCloneRequestSchema = z.object({
  templateId: uuid,
  sourceRevisionId: uuid,
  expectedHash: contentHash,
}).strict();

export const packagePublishRequestSchema = z.object({
  revisionId: uuid,
  makeDefault: z.boolean(),
  expectedHash: contentHash,
}).strict();

export const packageArchiveRequestSchema = z.object({
  revisionId: uuid,
  reason: z.string().trim().min(3).max(500),
  expectedHash: contentHash,
}).strict();

export const packageDraftResponseSchema = z.object({
  templateId: uuid,
  revisionId: uuid,
  created: z.boolean(),
  itemCount: z.number().int().min(1).max(25),
  contentHash,
}).strict();

export const packageCloneResponseSchema = z.object({
  templateId: uuid,
  revisionId: uuid,
  revisionNumber: z.number().int().positive(),
  itemCount: z.number().int().min(0).max(25),
  contentHash,
}).strict();

export const packagePublishResponseSchema = z.object({
  templateId: uuid,
  revisionId: uuid,
  revisionNumber: z.number().int().positive(),
  active: z.literal(true),
  default: z.boolean(),
  contentHash,
}).strict();

export const packageArchiveResponseSchema = z.object({
  templateId: uuid,
  revisionId: uuid,
  archived: z.literal(true),
  contentHash,
}).strict();

export function parsePackagePriceToCents(value: string): number | null {
  const normalized = value.trim();
  if (!/^\d{1,6}(?:[,.]\d{1,2})?$/.test(normalized)) return null;
  const [euros, decimals = ""] = normalized.replace(",", ".").split(".");
  const cents = Number(euros) * 100 + Number(decimals.padEnd(2, "0"));
  return Number.isSafeInteger(cents) && cents <= 10_000_000 ? cents : null;
}

export function formatPackagePrice(cents: number) {
  if (!Number.isInteger(cents) || cents < 0 || cents > 10_000_000) throw new Error("INVALID_PACKAGE_PRICE");
  return `${Math.floor(cents / 100)},${String(cents % 100).padStart(2, "0")}`;
}

export type PackageWorkspaceData = z.infer<typeof packageWorkspaceSchema>;
export type PackageDraftRequest = z.infer<typeof packageDraftRequestSchema>;
