import { z } from "zod";

const uuid = z.string().uuid();
const nonNegativeInteger = z.number().int().nonnegative();
export const dynamicImportStatusSchema = z.enum([
  "uploaded",
  "previewed",
  "processing",
  "committed",
  "failed",
  "expired",
]);

export const dynamicImportWorkspaceSchema = z.object({
  featureEnabled: z.boolean(),
  activeSeason: z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
  }).strict().nullable(),
  limits: z.object({
    maxBytes: z.literal(10 * 1024 * 1024),
    maxRows: z.literal(10_000),
    maxColumns: z.literal(64),
    maxCellLength: z.literal(512),
    retentionHoursDefault: z.literal(24),
    retentionHoursMinimum: z.literal(1),
    retentionHoursMaximum: z.literal(72),
  }).strict(),
  recentBatches: z.array(z.object({
    id: uuid,
    fileName: z.string().trim().min(1).max(255),
    status: dynamicImportStatusSchema,
    rowCount: z.number().int().min(1).max(10_000),
    createdAt: z.string().datetime({ offset: true }),
    expiresAt: z.string().datetime({ offset: true }),
    committedAt: z.string().datetime({ offset: true }).nullable(),
  }).strict()).max(10),
}).strict();

export const csvColumnInspectionSchema = z.object({
  index: z.number().int().min(0).max(63),
  label: z.string().min(1).max(120),
  uniqueValues: z.array(z.string().max(512)).max(100),
  uniqueValueCount: nonNegativeInteger,
  emptyCount: nonNegativeInteger,
  nonEmptyCount: nonNegativeInteger,
  valuesTruncated: z.boolean(),
}).strict();

export const dynamicImportUploadResponseSchema = z.object({
  batchId: uuid,
  status: dynamicImportStatusSchema,
  expiresAt: z.string().datetime({ offset: true }),
  reused: z.boolean(),
  diagnosis: z.object({
    fileName: z.string().min(1).max(255),
    encoding: z.literal("UTF-8"),
    delimiter: z.enum([",", ";"]),
    byteCount: z.number().int().min(1).max(10 * 1024 * 1024),
    rowCount: z.number().int().min(1).max(10_000),
    columnCount: z.number().int().min(1).max(64),
    rowShapeIssues: z.array(z.object({
      row: z.number().int().min(2).max(10_001),
      actualColumns: z.number().int().min(0).max(64),
    }).strict()).max(10_000),
  }).strict(),
  columns: z.array(csvColumnInspectionSchema).min(1).max(64),
}).strict();

export const stagedImportPayloadSchema = z.object({
  batchId: uuid,
  actorId: uuid,
  seasonId: uuid,
  previewRevision: z.number().int().nonnegative(),
  checksum: z.string().regex(/^[0-9a-f]{64}$/),
  fileName: z.string().min(1).max(255),
  delimiter: z.enum([",", ";"]),
  rowCount: z.number().int().min(1).max(10_000),
  columnCount: z.number().int().min(1).max(64),
  status: z.enum(["uploaded", "previewed", "processing"]),
  expiresAt: z.string().datetime({ offset: true }),
  ciphertext: z.string().min(24).max(14_000_000),
  nonce: z.string().length(16),
  keyVersion: z.literal(1),
  keyFingerprint: z.string().regex(/^[0-9a-f]{64}$/),
}).strict();

export const importStandardFieldSchema = z.enum([
  "external_member_id",
  "first_name",
  "insertion",
  "last_name",
  "email",
  "team",
  "date_of_birth",
  "gender",
  "active_for_season",
]);

export const importMappingTargetSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("ignore") }).strict(),
  z.object({
    kind: z.literal("member_field"),
    field: importStandardFieldSchema,
  }).strict(),
  z.object({
    kind: z.literal("product_size"),
    articleId: uuid,
  }).strict(),
]);

export const importMappingEntrySchema = z.object({
  columnIndex: z.number().int().min(0).max(63),
  sourceHeader: z.string().min(1).max(120),
  target: importMappingTargetSchema,
}).strict();

export const importPolicySchema = z.object({
  fillEmptyValues: z.literal(true),
  updateImportedUnconfirmedSizes: z.literal(true),
  protectConfirmedSizes: z.literal(true),
  ignoreEmptySourceValues: z.literal(true),
}).strict();

export const IMPORT_POLICY = {
  fillEmptyValues: true,
  updateImportedUnconfirmedSizes: true,
  protectConfirmedSizes: true,
  ignoreEmptySourceValues: true,
} as const;

export const importMappingSchema = z.object({
  entries: z.array(importMappingEntrySchema).min(1).max(64),
  policy: importPolicySchema,
}).strict().superRefine(({ entries }, context) => {
  const indexes = new Set<number>();
  const fields = new Set<string>();
  const articles = new Set<string>();
  let selected = 0;
  for (const [entryIndex, entry] of entries.entries()) {
    if (indexes.has(entry.columnIndex)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["entries", entryIndex, "columnIndex"],
        message: "Een bronkolom kan maar eenmaal worden gekoppeld.",
      });
    }
    indexes.add(entry.columnIndex);
    if (entry.target.kind === "ignore") continue;
    selected += 1;
    if (entry.target.kind === "member_field") {
      if (fields.has(entry.target.field)) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["entries", entryIndex, "target"],
          message: "Een standaardveld kan maar eenmaal worden gekoppeld.",
        });
      }
      fields.add(entry.target.field);
    } else {
      if (articles.has(entry.target.articleId)) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["entries", entryIndex, "target"],
          message: "Een productmaat kan maar eenmaal worden gekoppeld.",
        });
      }
      articles.add(entry.target.articleId);
    }
  }
  if (selected === 0) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["entries"],
      message: "Selecteer minimaal één kolom.",
    });
  }
});

export const dynamicImportMappingRequestSchema = z.object({
  batchId: uuid,
  expectedRevision: z.number().int().nonnegative(),
  expectedCatalogHash: z.string().regex(/^[0-9a-f]{64}$/),
  preset: z.object({
    id: uuid,
    revision: z.number().int().positive(),
  }).strict().nullable().default(null),
  mapping: importMappingSchema,
}).strict();

const catalogVariantSchema = z.object({
  id: uuid,
  label: z.string().min(1).max(80),
  code: z.string().min(1).max(120).nullable(),
  aliases: z.array(z.string().min(1).max(80)).max(25),
}).strict();

const mappingPresetTargetSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("member_field"),
    field: importStandardFieldSchema,
  }).strict(),
  z.object({
    kind: z.literal("product_size"),
    articleId: uuid,
  }).strict(),
]);

export const mappingPresetEntrySchema = z.object({
  sourceHeaderKey: z.string().min(1).max(120),
  target: mappingPresetTargetSchema,
}).strict();

export const mappingPresetSchema = z.object({
  id: uuid,
  name: z.string().min(1).max(80),
  revision: z.number().int().positive(),
  entries: z.array(mappingPresetEntrySchema).min(1).max(64),
}).strict();

export const dynamicImportMappingWorkspaceSchema = z.object({
  batchId: uuid,
  seasonId: uuid,
  revision: z.number().int().nonnegative(),
  catalogHash: z.string().regex(/^[0-9a-f]{64}$/),
  articles: z.array(z.object({
    id: uuid,
    code: z.string().min(2).max(24),
    name: z.string().min(1).max(120),
    importable: z.boolean(),
    matchConflicts: z.array(z.object({
      key: z.string(),
      variantIds: z.array(uuid),
      reason: z.string(),
    }).passthrough()),
    variants: z.array(catalogVariantSchema),
  }).strict()).max(500),
  presets: z.array(mappingPresetSchema).max(100),
}).strict();

export const sizeDiagnosticValueSchema = z.object({
  rawValue: z.string().max(512),
  count: nonNegativeInteger,
  outcome: z.enum(["recognized", "unknown", "unsafe"]),
  variantId: uuid.optional(),
  variantLabel: z.string().min(1).max(80).optional(),
  matchedBy: z.enum(["code", "label", "alias"]).optional(),
}).strict();

export const dynamicImportMappingResponseSchema = z.object({
  batchId: uuid,
  revision: z.number().int().positive(),
  mappingHash: z.string().regex(/^[0-9a-f]{64}$/),
  catalogHash: z.string().regex(/^[0-9a-f]{64}$/),
  reused: z.boolean(),
  sizeDiagnostics: z.array(z.object({
    columnIndex: z.number().int().min(0).max(63),
    articleId: uuid,
    articleName: z.string().min(1).max(120),
    totalCount: nonNegativeInteger,
    emptyCount: nonNegativeInteger,
    recognizedCount: nonNegativeInteger,
    unknownCount: nonNegativeInteger,
    unsafeCount: nonNegativeInteger,
    values: z.array(sizeDiagnosticValueSchema).max(10_000),
  }).strict()).max(64),
}).strict();

export const mappingPresetMutationSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("save"),
    presetId: uuid.optional(),
    expectedRevision: z.number().int().positive().optional(),
    name: z.string().trim().min(1).max(80),
    entries: z.array(mappingPresetEntrySchema).min(1).max(64),
  }).strict(),
  z.object({
    action: z.literal("archive"),
    presetId: uuid,
    expectedRevision: z.number().int().positive(),
  }).strict(),
]).superRefine((value, context) => {
  if (
    value.action === "save"
    && ((value.presetId === undefined) !== (value.expectedRevision === undefined))
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Preset-ID en revisie moeten samen worden opgegeven.",
    });
  }
});

export type DynamicImportWorkspaceData = z.infer<typeof dynamicImportWorkspaceSchema>;
export type DynamicImportUploadResponse = z.infer<typeof dynamicImportUploadResponseSchema>;
export type StagedImportPayload = z.infer<typeof stagedImportPayloadSchema>;
export type ImportMapping = z.infer<typeof importMappingSchema>;
export type ImportMappingTarget = z.infer<typeof importMappingTargetSchema>;
export type DynamicImportMappingWorkspace = z.infer<typeof dynamicImportMappingWorkspaceSchema>;
export type DynamicImportMappingResponse = z.infer<typeof dynamicImportMappingResponseSchema>;
export type MappingPreset = z.infer<typeof mappingPresetSchema>;
