import nodemailer from "nodemailer";
import { z } from "zod";
import type { EmailDeliveryResult, EmailMessage } from "@/server/email/provider-contract";

const email = z.string().trim().email().max(320);

export function smtpRuntimeHealth() {
  const port = Number(process.env.SMTP_PORT);
  const secure = process.env.SMTP_SECURE;
  const transportValid = (port === 587 && secure === "false")
    || (port === 465 && secure === "true");
  return {
    provider: "smtp" as const,
    providerConfigured: Boolean(
      process.env.SMTP_HOST === "mail.voetbalassist.nl"
      && transportValid
      && process.env.SMTP_USERNAME?.includes("@")
      && process.env.SMTP_PASSWORD
      && validName(process.env.SMTP_FROM_NAME)
      && email.safeParse(process.env.SMTP_FROM_EMAIL).success
      && email.safeParse(process.env.SMTP_REPLY_TO_EMAIL).success,
    ),
  };
}

function validName(value: string | undefined) {
  const name = value?.trim();
  return Boolean(name && name.length >= 3 && name.length <= 120 && !/[\r\n]/u.test(name));
}

function configuration() {
  if (process.env.EMAIL_ENABLED !== "true") return { enabled: false as const };
  const health = smtpRuntimeHealth();
  if (!health.providerConfigured) return { enabled: true as const, configured: false as const };
  const port = Number(process.env.SMTP_PORT);
  return {
    enabled: true as const,
    configured: true as const,
    host: "mail.voetbalassist.nl",
    port,
    secure: port === 465,
    username: process.env.SMTP_USERNAME!,
    password: process.env.SMTP_PASSWORD!,
    fromName: process.env.SMTP_FROM_NAME!.trim(),
    fromEmail: email.parse(process.env.SMTP_FROM_EMAIL),
    replyToEmail: email.parse(process.env.SMTP_REPLY_TO_EMAIL),
  };
}

type SmtpError = Error & { code?: string; responseCode?: number; command?: string };
const transientTransportCodes = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "ETIMEDOUT",
  "ESOCKET",
  "EPIPE",
]);

export function classifySmtpError(error: unknown): EmailDeliveryResult {
  const smtp = error as SmtpError;
  const responseCode = Number.isInteger(smtp?.responseCode) ? smtp.responseCode : undefined;
  const providerCode = responseCode ? String(responseCode) : smtp?.code?.slice(0, 40);
  if (responseCode === 535 || smtp?.code === "EAUTH") {
    return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode };
  }
  if (responseCode && responseCode >= 400 && responseCode < 500) {
    return { delivered: false, reason: "provider_rejected", outcome: "retry", providerCode };
  }
  if (responseCode && responseCode >= 500) {
    return { delivered: false, reason: "provider_rejected", outcome: "failed", providerCode };
  }
  const duringData = smtp?.command === "DATA" || smtp?.command === "DOT";
  if (duringData) {
    return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain", providerCode };
  }
  if (smtp?.code && transientTransportCodes.has(smtp.code)) {
    return { delivered: false, reason: "provider_rejected", outcome: "retry", providerCode };
  }
  return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode };
}

export async function sendSmtpEmail(message: EmailMessage): Promise<EmailDeliveryResult> {
  const config = configuration();
  if (!config.enabled) return { delivered: false, reason: "disabled", outcome: "failed" };
  if (!config.configured) return { delivered: false, reason: "configuration_error", outcome: "failed" };
  if (
    message.fromName !== config.fromName
    || message.fromEmail !== config.fromEmail
    || message.replyToEmail !== config.replyToEmail
  ) return { delivered: false, reason: "configuration_error", outcome: "failed" };
  try {
    const transporter = nodemailer.createTransport({
      host: config.host,
      port: config.port,
      secure: config.secure,
      requireTLS: !config.secure,
      auth: { user: config.username, pass: config.password },
      connectionTimeout: 10_000,
      greetingTimeout: 10_000,
      socketTimeout: 15_000,
    });
    const result = await transporter.sendMail({
      envelope: { from: config.fromEmail, to: message.recipientEmail },
      from: { name: config.fromName, address: config.fromEmail },
      replyTo: config.replyToEmail,
      to: message.recipientEmail,
      subject: message.subject,
      text: message.text,
      html: message.html,
      headers: message.headers,
    });
    const providerMessageId = result.messageId?.trim();
    if (!providerMessageId || !result.accepted?.length) {
      return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" };
    }
    return { delivered: true, providerMessageId };
  } catch (error) {
    return classifySmtpError(error);
  }
}

export async function verifySmtpConnection() {
  const config = configuration();
  if (!config.enabled || !config.configured) return false;
  const transporter = nodemailer.createTransport({
    host: config.host, port: config.port, secure: config.secure,
    requireTLS: !config.secure,
    auth: { user: config.username, pass: config.password },
  });
  return transporter.verify();
}
