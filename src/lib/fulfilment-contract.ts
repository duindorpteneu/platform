import { z } from "zod";

const fulfilmentLineSchema = z.object({
  id: z.string().uuid(),
  article: z.string().min(1).max(240),
  size: z.string().min(1).max(120),
  status: z.enum(["backorder", "ready_for_pickup", "picked_up", "cancelled"]),
}).strict();

const fulfilmentFoundSchema = z.object({
  status: z.literal("found"),
  orderId: z.string().uuid(),
  paid: z.boolean(),
  member: z.object({
    name: z.string().min(1).max(320),
    team: z.string().min(1).max(160),
    relationNumberSuffix: z.string().min(1).max(4).nullable(),
  }).strict(),
  lines: z.array(fulfilmentLineSchema).max(100),
}).strict();

export const fulfilmentLookupResponseSchema = z.discriminatedUnion("status", [
  fulfilmentFoundSchema,
  z.object({ status: z.literal("invalid") }).strict(),
]);

export type FulfilmentLookupFound = z.infer<typeof fulfilmentFoundSchema>;

export function formatLegacyIssuanceMemberMeta(
  member: FulfilmentLookupFound["member"],
) {
  return member.relationNumberSuffix
    ? `${member.team} · relatienummer eindigt op ${member.relationNumberSuffix}`
    : `${member.team} · geen relatienummer`;
}
