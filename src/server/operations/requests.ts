import { z } from "zod";

export const qrManagementRequestSchema = z.object({
  orderId: z.string().uuid(),
  action: z.enum(["rotate", "revoke"]),
  reason: z.string().trim().min(4).max(500),
  requestId: z.string().uuid(),
}).strict();

export const fulfilmentCorrectionRequestSchema = z.object({
  orderLineIds: z.array(z.string().uuid()).min(1).max(25),
  targetStatus: z.enum(["ready_for_pickup", "backorder"]),
  reason: z.string().trim().min(4).max(500),
  requestId: z.string().uuid(),
}).strict().superRefine((value, context) => {
  if (new Set(value.orderLineIds).size !== value.orderLineIds.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["orderLineIds"], message: "Een regel mag maar één keer worden gecorrigeerd." });
  }
});
