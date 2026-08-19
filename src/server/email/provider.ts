import type { z } from "zod";
import { mailTestEmailSchema, parentOtpEmailSchema, renderedEmailJobSchema, type EmailDeliveryResult, type EmailProviderHealth } from "./provider-contract";
import * as sendgrid from "./providers/sendgrid";
import * as ses from "./providers/ses";

export type { EmailDeliveryResult } from "./provider-contract";
function selected() { return process.env.EMAIL_PROVIDER?.trim().toLowerCase(); }
function configurationFailure(): EmailDeliveryResult { return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode: "email_provider_invalid" }; }
export function emailProviderRuntimeHealth(): EmailProviderHealth {
  const runtimeValueValid = ["true", "false"].includes(process.env.EMAIL_ENABLED?.trim() ?? "");
  const runtimeEnabled = process.env.EMAIL_ENABLED === "true";
  const provider = selected();
  if (provider === "ses") return ses.sesRuntimeHealth();
  if (provider === "sendgrid") { const health = sendgrid.sendGridRuntimeHealth(); return { ...health, provider, credentialsValid: health.keyFingerprintMatches }; }
  return { runtimeValueValid, runtimeEnabled, provider: null, providerConfigured: false, credentialsValid: false, keyFingerprintMatches: false };
}
export async function sendEmailJob(message: z.input<typeof renderedEmailJobSchema>): Promise<EmailDeliveryResult> {
  if (selected() === "ses") return ses.sendEmailJob(message);
  if (selected() === "sendgrid") return sendgrid.sendEmailJob(message);
  return configurationFailure();
}
export async function sendParentOtpV2Email(message: z.input<typeof parentOtpEmailSchema>): Promise<EmailDeliveryResult> {
  if (selected() === "ses") return ses.sendParentOtpV2Email(message);
  if (selected() === "sendgrid") return sendgrid.sendParentOtpV2Email(message);
  return configurationFailure();
}
export async function sendMailV2TestEmail(message: z.input<typeof mailTestEmailSchema>): Promise<EmailDeliveryResult> {
  if (selected() === "ses") return ses.sendMailV2TestEmail(message);
  if (selected() === "sendgrid") return sendgrid.sendMailV2TestEmail(message);
  return configurationFailure();
}
export function selectedEmailSender() {
  const prefix = selected() === "ses" ? "SES" : selected() === "sendgrid" ? "SENDGRID" : null;
  return prefix ? { fromName: process.env[`${prefix}_FROM_NAME`] ?? "", fromEmail: process.env[`${prefix}_FROM_EMAIL`] ?? "", replyToEmail: process.env[`${prefix}_REPLY_TO_EMAIL`] ?? "" } : { fromName: "", fromEmail: "", replyToEmail: "" };
}
export function emailSmokeRecipient() { return selected() === "ses" ? process.env.SES_SMOKE_RECIPIENT : selected() === "sendgrid" ? process.env.SENDGRID_SMOKE_RECIPIENT : undefined; }
