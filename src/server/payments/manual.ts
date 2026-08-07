import { z } from "zod";

export const manualPaymentRequestSchema = z.object({
  orderId: z.string().uuid(),
  method: z.enum(["cash", "card"]),
  amountCents: z.number().int().positive().max(10_000_000),
  reason: z.string().trim().min(4).max(500),
  requestId: z.string().uuid(),
}).strict();

export type ManualPaymentRequest = z.infer<typeof manualPaymentRequestSchema>;

export const manualPaymentRefundRequestSchema = z.object({
  orderId: z.string().uuid(),
  paymentId: z.string().uuid(),
  amountCents: z.number().int().positive().max(10_000_000),
  reason: z.string().trim().min(4).max(500),
  evidenceReference: z.string().trim().min(4).max(160),
  requestId: z.string().uuid(),
}).strict();

export const manualPaymentRefundResponseSchema = z.object({
  requestId: z.string().uuid(),
  paymentId: z.string().uuid(),
  orderId: z.string().uuid(),
  memberSeasonId: z.string().uuid(),
  seasonId: z.string().uuid(),
  packageSnapshotId: z.string().uuid(),
  status: z.literal("refunded"),
  method: z.enum(["cash", "card"]),
  amountCents: z.number().int().positive(),
  currency: z.literal("EUR"),
  refundedAt: z.string().datetime({ offset: true }),
  releasedAllocationCount: z.number().int().nonnegative(),
  qrRevoked: z.boolean(),
  refundCreated: z.literal(false),
  refundExternallyConfirmed: z.literal(true),
  reused: z.boolean(),
}).strict();

export type ManualPaymentRefundRequest = z.infer<
  typeof manualPaymentRefundRequestSchema
>;
