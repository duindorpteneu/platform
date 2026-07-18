import { z } from "zod";

export const manualPaymentRequestSchema = z.object({
  orderId: z.string().uuid(),
  method: z.enum(["cash", "card"]),
}).strict();

export type ManualPaymentRequest = z.infer<typeof manualPaymentRequestSchema>;
