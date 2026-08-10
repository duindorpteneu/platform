import { z } from "zod";

const uuid = z.string().uuid();
const revision = z.string().regex(/^[a-f0-9]{64}$/);

export const packageChangeRequestSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("preflight"),
    orderId: uuid,
    targetPackageRevisionId: uuid,
    reason: z.string().trim().min(4).max(480),
    requestId: uuid,
  }).strict(),
  z.object({
    action: z.literal("apply"),
    requestId: uuid,
    revision,
    confirmation: z.enum([
      "SWITCH_PACKAGE",
      "RELEASE_ALLOCATIONS_AND_SWITCH",
    ]),
  }).strict(),
]);

const appliedResultSchema = z.object({
  requestId: uuid,
  orderId: uuid,
  memberSeasonId: uuid,
  fromSnapshotId: uuid,
  toSnapshotId: uuid,
  toPackageRevisionId: uuid,
  priceDeltaCents: z.number().int(),
  releasedAllocationCount: z.number().int().nonnegative(),
  paymentTransferred: z.literal(false),
  refundCreated: z.literal(false),
  status: z.literal("applied"),
}).strict();

export const packageChangeResponseSchema = z.object({
  requestId: uuid,
  orderId: uuid,
  memberSeasonId: uuid,
  fromSnapshotId: uuid,
  fromPackageRevisionId: uuid.nullable(),
  fromPackageName: z.string().min(1).max(120),
  fromPriceCents: z.number().int().nonnegative(),
  fromCurrency: z.string().regex(/^[A-Z]{3}$/),
  toPackageRevisionId: uuid,
  toPackageName: z.string().min(1).max(120),
  toPriceCents: z.number().int().nonnegative(),
  toCurrency: z.string().regex(/^[A-Z]{3}$/),
  priceDeltaCents: z.number().int(),
  paymentStatus: z.string().min(1).max(40),
  unresolvedPaymentCount: z.number().int().nonnegative(),
  paidHistoryCount: z.number().int().nonnegative(),
  refundedPaymentCount: z.number().int().nonnegative(),
  reservedAllocationCount: z.number().int().nonnegative(),
  fulfilledAllocationCount: z.number().int().nonnegative(),
  requiresPaymentResolution: z.boolean(),
  requiresExternalRefund: z.boolean(),
  requiresAllocationRelease: z.boolean(),
  blockedByFulfilment: z.boolean(),
  blockedByReconciliation: z.boolean(),
  canApply: z.boolean(),
  status: z.enum(["blocked", "ready", "applied", "superseded", "dismissed"]),
  revision,
  reused: z.boolean(),
  result: appliedResultSchema.nullable(),
}).strict();

export type PackageChangeResponse = z.infer<
  typeof packageChangeResponseSchema
>;
