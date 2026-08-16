import { z } from "zod";

const uuid = z.string().uuid();

export const looseOrderLineRemovalRequestSchema = z.object({
  orderLineId: uuid,
  reason: z.string().trim().min(3).max(500),
  requestId: uuid,
}).strict();

export const looseOrderLineRemovalResponseSchema = z.object({
  requestId: uuid,
  orderId: uuid,
  orderLineId: uuid,
  status: z.literal("cancelled"),
  reused: z.boolean(),
}).strict();

export type LooseOrderLineRemovalResponse = z.infer<
  typeof looseOrderLineRemovalResponseSchema
>;
