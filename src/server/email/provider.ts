import type { EmailDeliveryResult, EmailMessage } from "@/server/email/provider-contract";
import { sendSmtpEmail, smtpRuntimeHealth } from "@/server/email/providers/smtp";
import { sendEmailJob as sendGridJob, sendMailV2TestEmail as sendGridTest, sendParentOtpV2Email as sendGridOtp, sendParentOtpEmail as sendGridLegacyOtp, sendGridRuntimeHealth } from "@/server/email/sendgrid";

export type { EmailDeliveryResult } from "@/server/email/provider-contract";

function selectedProvider() {
  const value = process.env.EMAIL_PROVIDER?.trim();
  return value === "smtp" || value === "sendgrid" ? value : null;
}

export function emailRuntimeHealth() {
  const runtimeValue = process.env.EMAIL_ENABLED?.trim();
  const provider = selectedProvider();
  const base = { runtimeValueValid: runtimeValue === "true" || runtimeValue === "false", runtimeEnabled: runtimeValue === "true", provider };
  if (provider === "smtp") return { ...base, ...smtpRuntimeHealth(), keyFingerprintMatches: true };
  if (provider === "sendgrid") return { ...base, ...sendGridRuntimeHealth() };
  return { ...base, providerConfigured: false, keyFingerprintMatches: false };
}

function smtpMessage(message: EmailMessage) { return sendSmtpEmail(message); }

export async function sendEmailJob(message: EmailMessage & { jobId: string; deliveryAttemptId: string }): Promise<EmailDeliveryResult> {
  const provider = selectedProvider();
  if (provider === "smtp") return smtpMessage(message);
  if (provider === "sendgrid") return sendGridJob(message);
  return { delivered: false, reason: "configuration_error", outcome: "failed" };
}

export async function sendParentOtpV2Email(message: EmailMessage & { deliveryAttemptId: string }): Promise<EmailDeliveryResult> {
  const provider = selectedProvider();
  if (provider === "smtp") return smtpMessage(message);
  if (provider === "sendgrid") return sendGridOtp(message);
  return { delivered: false, reason: "configuration_error", outcome: "failed" };
}

export async function sendMailV2TestEmail(message: Omit<EmailMessage, "recipientEmail"> & { testDeliveryId: string }): Promise<EmailDeliveryResult> {
  const provider = selectedProvider();
  if (provider === "smtp") {
    const recipientEmail = process.env.EMAIL_SMOKE_RECIPIENT ?? "";
    return smtpMessage({ ...message, recipientEmail, headers: { "X-Duindorp-Acceptance": message.testDeliveryId } });
  }
  if (provider === "sendgrid") return sendGridTest(message);
  return { delivered: false, reason: "configuration_error", outcome: "failed" };
}

export async function sendParentOtpEmail(recipientEmail: string, message: Pick<EmailMessage, "subject" | "text" | "html">) {
  if (selectedProvider() === "smtp") {
    const result = await smtpMessage({ ...message, recipientEmail, fromName: process.env.SMTP_FROM_NAME ?? "", fromEmail: process.env.SMTP_FROM_EMAIL ?? "", replyToEmail: process.env.SMTP_REPLY_TO_EMAIL ?? "" });
    return result.delivered ? { delivered: true as const } : { delivered: false as const, reason: result.reason };
  }
  if (selectedProvider() === "sendgrid") return sendGridLegacyOtp(recipientEmail, message);
  return { delivered: false as const, reason: "configuration_error" as const };
}
