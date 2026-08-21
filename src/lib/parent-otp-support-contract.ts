import { z } from "zod";

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });

export const parentOtpSupportSchema = z.object({
  parentAccountId: uuid,
  status: z.literal("active"),
  loginEmailMasked: z.string().min(5).max(320),
  lastCodeRequestedAt: timestamp.nullable(),
  lastDeliveryAttemptAt: timestamp.nullable(),
  lastDeliveryStatus: z.enum([
    "provider_accepted",
    "provider_rejected",
    "delivery_uncertain",
    "configuration_error",
    "disabled",
    "render_failed",
  ]).nullable(),
  codeExpiresAt: timestamp.nullable(),
  lastSuccessfulLoginAt: timestamp.nullable(),
  linkedChildren: z.array(z.object({
    memberId: uuid,
    memberSeasonId: uuid,
    memberName: z.string().min(1).max(320),
    team: z.string().min(1).max(160),
  }).strict()).min(1).max(500),
}).strict();

export const parentOtpSupportActionSchema = z.object({
  parentAccountId: uuid,
  mode: z.enum(["resend", "reset"]),
}).strict();

export const parentOtpSupportActionResponseSchema = z.object({
  outcome: z.enum([
    "provider_accepted",
    "provider_rejected",
    "delivery_uncertain",
    "configuration_error",
    "disabled",
    "render_failed",
  ]),
  reused: z.boolean(),
  expiresAt: timestamp,
}).strict();

export type ParentOtpSupport = z.infer<typeof parentOtpSupportSchema>;
export type ParentOtpSupportActionResponse = z.infer<
  typeof parentOtpSupportActionResponseSchema
>;
