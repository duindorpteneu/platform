import { z } from "zod";

const fulfilmentLineSchema = z.object({
  id: z.string().uuid(),
  article: z.string().min(1).max(240),
  size: z.string().min(1).max(120),
  quantity: z.number().int().min(1).max(25),
  status: z.enum([
    "backorder",
    "ready_for_pickup",
    "picked_up",
  ]),
}).strict();

const fulfilmentFoundSchema = z.object({
  status: z.literal("found"),
  grantExpiresAt: z.string().datetime({ offset: true }),
  member: z.object({
    firstName: z.string().min(1).max(160),
    gender: z.enum(["male", "female", "other", "unknown"]),
  }).strict(),
  lines: z.array(fulfilmentLineSchema).max(100),
  scanGrant: z.string().regex(/^sg2\.k[1-9]\d{0,3}\.[A-Za-z0-9_-]{43}$/),
}).strict();

export const fulfilmentExchangeResponseSchema = z.discriminatedUnion("status", [
  fulfilmentFoundSchema,
  z.object({ status: z.literal("invalid") }).strict(),
]);

export const fulfilmentCommitResponseSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("completed"),
    issuedLines: z.number().int().min(1).max(25),
    completedAt: z.string().datetime({ offset: true }),
    outcome: z.enum(["partial_pickup", "package_complete"]),
    reused: z.boolean(),
  }).strict(),
  z.object({ status: z.enum(["stale", "blocked"]) }).strict(),
]);

export type FulfilmentExchangeFound = z.infer<typeof fulfilmentFoundSchema>;

export function formatIssuanceGender(
  gender: FulfilmentExchangeFound["member"]["gender"],
) {
  return {
    male: "Jongen/man",
    female: "Meisje/vrouw",
    other: "Anders",
    unknown: "Niet geregistreerd",
  }[gender];
}
