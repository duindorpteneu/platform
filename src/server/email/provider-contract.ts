import { z } from "zod";

export const emailAddressSchema = z.string().trim().email().max(320);
export const renderedEmailJobSchema = z.object({
  jobId: z.string().uuid(), deliveryAttemptId: z.string().uuid(),
  recipientEmail: emailAddressSchema, subject: z.string().trim().min(1).max(200),
  text: z.string().trim().min(1).max(20_000), html: z.string().trim().min(1).max(50_000),
  fromName: z.string().trim().min(3).max(120).refine((value) => !/[\r\n]/u.test(value)),
  fromEmail: emailAddressSchema, replyToEmail: emailAddressSchema,
}).strict();
export const parentOtpEmailSchema = renderedEmailJobSchema.omit({ jobId: true }).strict();
export const mailTestEmailSchema = renderedEmailJobSchema.omit({ jobId: true, deliveryAttemptId: true, recipientEmail: true }).extend({ testDeliveryId: z.string().uuid() }).strict();
export type EmailDeliveryResult = { delivered: true; providerMessageId: string } | {
  delivered: false;
  reason: "disabled" | "configuration_error" | "provider_rejected" | "delivery_uncertain";
  outcome: "retry" | "failed" | "delivery_uncertain";
  providerCode?: string;
};
export type EmailProviderHealth = { runtimeValueValid: boolean; runtimeEnabled: boolean; provider: "ses" | "sendgrid" | null; providerConfigured: boolean; credentialsValid: boolean; keyFingerprintMatches: boolean };
