import { z } from "zod";

const countSchema = z.number().int().nonnegative();

export const paymentWorkspaceSchema = z.object({
  summary: z.object({
    open: countSchema,
    pending: countSchema,
    paid: countSchema,
    duplicatePaid: countSchema,
    refunded: countSchema,
    review: countSchema,
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
}).strict();

export type PaymentWorkspace = z.infer<typeof paymentWorkspaceSchema>;
