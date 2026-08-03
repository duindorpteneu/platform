import { z } from "zod";

export const manualPaymentRequestSchema = z.object({
  orderId: z.string().uuid(),
  method: z.enum(["cash", "card"]),
  amountCents: z.number().int().positive().max(10_000_000),
  reason: z.string().trim().min(4).max(500),
  requestId: z.string().uuid(),
}).strict();

export type ManualPaymentRequest = z.infer<typeof manualPaymentRequestSchema>;
