import { z } from "zod";

const uuidSchema = z.string().uuid();
const httpsUrlSchema = z.string().url().refine((value) => {
  const url = new URL(value);
  return url.protocol === "https:" && (url.hostname === "mollie.com" || url.hostname.endsWith(".mollie.com"));
}, { message: "Alleen een beveiligde Mollie-checkout is toegestaan." });

export const mollieCreateRequestSchema = z.object({
  orderId: uuidSchema,
}).strict();

export const mollieCheckoutResponseSchema = z.object({
  checkoutUrl: httpsUrlSchema,
}).strict();

export const preparedMolliePaymentSchema = z.object({
  paymentId: uuidSchema,
  orderId: uuidSchema,
  amountCents: z.number().int().positive(),
  currency: z.literal("EUR"),
  status: z.enum(["open", "pending"]),
  providerPaymentId: z.string().regex(/^tr_[A-Za-z0-9]+$/).nullable(),
  checkoutUrl: httpsUrlSchema.nullable(),
  reused: z.boolean(),
  idempotencyKey: z.string().trim().min(8).max(160),
  metadata: z.object({
    payment_id: uuidSchema,
    order_id: uuidSchema,
    member_id: uuidSchema,
    member_season_id: uuidSchema,
    season_id: uuidSchema,
    schema_version: z.literal(2),
  }).strict(),
}).strict().superRefine((value, context) => {
  if (value.paymentId !== value.metadata.payment_id || value.orderId !== value.metadata.order_id) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "De betaalmetadata komt niet overeen." });
  }
});

export const mollieReconciliationContextSchema = z.object({
  paymentId: uuidSchema,
  providerPaymentId: z.string().regex(/^tr_[A-Za-z0-9]+$/),
  paymentStatus: z.enum(["open", "pending", "paid", "failed", "canceled", "expired", "refunded", "duplicate_paid"]),
  amountCents: z.number().int().positive(),
  currency: z.literal("EUR"),
  metadataSchemaVersion: z.union([z.literal(1), z.literal(2)]),
  orderId: uuidSchema,
  memberId: uuidSchema,
  memberSeasonId: uuidSchema,
  seasonId: uuidSchema,
  amountDueCents: z.number().int().positive(),
}).strict();

export const mollieReconciliationResultSchema = z.union([
  z.object({
    paymentId: uuidSchema,
    orderId: uuidSchema,
    effect: z.enum(["updated", "paid", "refunded", "already_processed", "duplicate_paid", "stale_ignored", "terminal_ignored"]),
    status: z.enum(["open", "pending", "paid", "failed", "canceled", "expired", "refunded", "duplicate_paid"]),
  }).passthrough(),
  z.object({
    paymentId: uuidSchema,
    effect: z.literal("event_replay"),
    status: z.literal("replay"),
    eventType: z.enum(["observed", "paid", "duplicate_paid", "refunded", "stale_ignored", "terminal_ignored", "replay", "mismatch"]),
  }).passthrough(),
  z.object({
    paymentId: uuidSchema,
    effect: z.literal("mismatch"),
    status: z.literal("manual_review"),
    issue: z.string().min(1).max(500),
  }).passthrough(),
]);

export type MollieCreateRequest = z.infer<typeof mollieCreateRequestSchema>;
export type PreparedMolliePayment = z.infer<typeof preparedMolliePaymentSchema>;
export type MollieReconciliationContext = z.infer<typeof mollieReconciliationContextSchema>;
