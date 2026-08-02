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

export type DynamicImportWorkspaceData = z.infer<typeof dynamicImportWorkspaceSchema>;
export type DynamicImportUploadResponse = z.infer<typeof dynamicImportUploadResponseSchema>;
export type StagedImportPayload = z.infer<typeof stagedImportPayloadSchema>;
