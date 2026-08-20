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
  adjustmentId: uuid,
  orderId: uuid,
  memberSeasonId: uuid,
  fromSnapshotId: uuid,
  toSnapshotId: uuid,
  toPackageRevisionId: uuid,
  priceDeltaCents: z.number().int(),
  creditAppliedCents: z.number().int().nonnegative(),
  additionalDueCents: z.number().int().nonnegative(),
  refundDueCents: z.number().int().nonnegative(),
  releasedAllocationCount: z.number().int().nonnegative(),
  targetSizesConfirmed: z.boolean(),
  materialization: z.object({
    orderLinesMaterialized: z.number().int().nonnegative(),
    snapshotItemsLinked: z.number().int().nonnegative(),
  }).passthrough(),
  paymentTransferred: z.literal(false),
  refunds: z.array(z.object({
    refundId: uuid,
    paymentId: uuid,
    method: z.enum(["mollie", "cash", "card"]),
    amountCents: z.number().int().positive(),
    status: z.enum(["due", "manual_due"]),
  }).strict()),
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
  effectivePaidCents: z.number().int().nonnegative(),
  creditAvailableCents: z.number().int().nonnegative(),
  creditAppliedCents: z.number().int().nonnegative(),
  additionalDueCents: z.number().int().nonnegative(),
  refundDueCents: z.number().int().nonnegative(),
  paymentMethod: z.enum(["mollie", "cash", "card", "mixed"]).nullable(),
  paymentSources: z.array(z.object({
    paymentId: uuid,
    method: z.enum(["mollie", "cash", "card"]),
    amountCents: z.number().int().positive(),
    paidAt: z.string().datetime({ offset: true }).nullable(),
  }).strict()),
  unresolvedPaymentCount: z.number().int().nonnegative(),
  reservedAllocationCount: z.number().int().nonnegative(),
  fulfilledAllocationCount: z.number().int().nonnegative(),
  requiresAllocationRelease: z.boolean(),
  blockedByFulfilment: z.boolean(),
  blockedByReconciliation: z.boolean(),
  targetPackageRequiredSizeCount: z.number().int().nonnegative(),
  targetPackageKnownSizeCount: z.number().int().nonnegative(),
  targetPackageMissingSizeCount: z.number().int().nonnegative(),
  canApply: z.boolean(),
  status: z.enum(["blocked", "ready", "applied", "superseded", "dismissed"]),
  revision,
  reused: z.boolean(),
  result: appliedResultSchema.nullable(),
}).strict();

export type PackageChangeResponse = z.infer<
  typeof packageChangeResponseSchema
>;
