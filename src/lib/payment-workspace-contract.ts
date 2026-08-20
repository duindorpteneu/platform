import { z } from "zod";

const countSchema = z.number().int().nonnegative();

export const paymentWorkspaceSchema = z.object({
  canRecordRefund: z.boolean().default(false),
  summary: z.object({
    open: countSchema,
    pending: countSchema,
    paid: countSchema,
    duplicatePaid: countSchema,
    refunded: countSchema,
    review: countSchema,
    refundProcessing: countSchema.default(0),
    manualRefundRequired: countSchema.default(0),
    additionalPaymentRequired: countSchema.default(0),
    refundReconciliationRequired: countSchema.default(0),
  }).strict(),
  attempts: z.array(z.object({
    paymentId: z.string().uuid(),
    orderId: z.string().uuid(),
    memberName: z.string().min(1).max(320),
    relationNumber: z.string().min(1).max(120).nullable(),
    team: z.string().min(1).max(160),
    method: z.enum(["cash", "card", "mollie"]),
    status: z.enum(["open", "pending", "paid", "failed", "canceled", "expired", "refunded", "duplicate_paid"]),
    amountCents: z.number().int().nonnegative(),
    currency: z.literal("EUR"),
    providerPaymentId: z.string().max(160).nullable(),
    reconciliationIssue: z.string().max(500).nullable(),
    createdAt: z.string().datetime({ offset: true }),
    reconciledAt: z.string().datetime({ offset: true }).nullable(),
  }).strict()).max(100),
  refunds: z.array(z.object({
    refundId: z.string().uuid(),
    paymentId: z.string().uuid(),
    orderId: z.string().uuid(),
    memberName: z.string().min(1).max(320),
    relationNumber: z.string().min(1).max(120).nullable(),
    method: z.enum(["cash", "card", "mollie"]),
    amountCents: z.number().int().positive(),
    currency: z.literal("EUR"),
    status: z.enum(["due", "requesting", "queued", "pending", "processing", "completed", "failed", "canceled", "manual_due", "manual_completed", "reconciliation_required"]),
    providerRefundId: z.string().regex(/^re_[A-Za-z0-9]+$/).nullable(),
    providerStatus: z.enum(["queued", "pending", "processing", "refunded", "failed", "canceled"]).nullable(),
    retryable: z.boolean(),
    fromPackage: z.string().min(1).max(120),
    toPackage: z.string().min(1).max(120),
    createdAt: z.string().datetime({ offset: true }),
    updatedAt: z.string().datetime({ offset: true }),
  }).strict()).max(100).default([]),
}).strict();

export type PaymentWorkspace = z.infer<typeof paymentWorkspaceSchema>;
