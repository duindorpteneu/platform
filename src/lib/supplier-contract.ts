import { z } from "zod";

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });
const count = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);

export const SUPPLIER_GENDERS = [
  "male",
  "female",
  "other",
  "unknown",
] as const;

export const supplierAccessTokenSchema = z.string()
  .trim()
  .regex(/^dsv_supplier_[A-Za-z0-9_-]{43}$/);

export const supplierSessionTokenSchema = z.string()
  .regex(/^[A-Za-z0-9_-]{43}$/);

export const supplierSeasonSchema = z.object({
  id: uuid,
  name: z.string().min(1).max(120),
}).strict();

export const supplierContextSchema = z.object({
  principalId: uuid,
  displayName: z.string().min(2).max(120),
  activeSeason: supplierSeasonSchema.nullable(),
  seasons: z.array(supplierSeasonSchema).max(100),
}).strict();

export type SupplierContext = z.infer<typeof supplierContextSchema>;

export const supplierPrincipalSchema = z.object({
  id: uuid,
  displayName: z.string().min(2).max(120),
  active: z.boolean(),
  tokenVersion: z.number().int().positive(),
  createdAt: timestamp,
  updatedAt: timestamp,
  disabledAt: timestamp.nullable(),
  seasonIds: z.array(uuid).max(100),
  activeSessions: count,
  lastUsedAt: timestamp.nullable(),
}).strict();

export const supplierAdminWorkspaceSchema = z.object({
  principals: z.array(supplierPrincipalSchema).max(100),
  seasons: z.array(supplierSeasonSchema.extend({
    status: z.literal("open"),
  }).strict()).max(100),
}).strict();

export const supplierAdminActionSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("create"),
    displayName: z.string().trim().min(2).max(120),
    seasonIds: z.array(uuid).min(1).max(100),
    requestId: uuid,
  }).strict(),
  z.object({
    action: z.literal("rotate"),
    principalId: uuid,
    reason: z.string().trim().min(4).max(500),
    requestId: uuid,
  }).strict(),
  z.object({
    action: z.literal("disable"),
    principalId: uuid,
    reason: z.string().trim().min(4).max(500),
    requestId: uuid,
  }).strict(),
  z.object({
    action: z.literal("set_seasons"),
    principalId: uuid,
    seasonIds: z.array(uuid).min(1).max(100),
    reason: z.string().trim().min(4).max(500),
    requestId: uuid,
  }).strict(),
]);

export const supplierAdminResultSchema = z.object({
  action: z.enum(["create", "rotate", "disable", "set_seasons"]),
  alreadyProcessed: z.boolean(),
  principal: supplierPrincipalSchema,
}).strict();

export const supplierLoginRequestSchema = z.object({
  accessToken: supplierAccessTokenSchema,
}).strict();

export const supplierPlanningSchema = z.object({
  season: supplierSeasonSchema,
  generatedAt: timestamp,
  lowStockThreshold: count,
  inventory: z.array(z.object({
    productName: z.string().min(1).max(120),
    productCode: z.string().min(1).max(24),
    size: z.string().min(1).max(80),
    supplierCode: z.string().max(120).nullable(),
    productActive: z.boolean(),
    variantActive: z.boolean(),
    physical: count,
    reserved: count,
    issued: count,
    free: z.number().int().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER),
    totalOpenDemand: count,
    shortage: count,
  }).strict()).max(10_000),
  demandByGender: z.array(z.object({
    productName: z.string().min(1).max(120),
    productCode: z.string().min(1).max(24),
    size: z.string().min(1).max(80),
    supplierCode: z.string().max(120).nullable(),
    gender: z.enum(SUPPLIER_GENDERS),
    totalOpenDemand: count,
    paidWaiting: count,
    unpaidDemand: count,
    unconfirmedDemand: count,
    pickedUp: count,
  }).strict()).max(40_000),
  unresolvedSizeDemand: z.array(z.object({
    productName: z.string().min(1).max(120),
    productCode: z.string().min(1).max(24),
    gender: z.enum(SUPPLIER_GENDERS),
    totalDemand: count,
    paidDemand: count,
    unpaidDemand: count,
    missing: count,
    unconfirmed: count,
    conflict: count,
  }).strict()).max(40_000),
}).strict();

export type SupplierPlanning = z.infer<typeof supplierPlanningSchema>;

export const SUPPLIER_FORBIDDEN_RESPONSE_KEYS = [
  "member",
  "memberId",
  "memberName",
  "firstName",
  "lastName",
  "email",
  "dateOfBirth",
  "dob",
  "team",
  "relationNumber",
  "orderId",
  "paymentId",
  "amountCents",
  "paidAt",
  "fifoAt",
] as const;
