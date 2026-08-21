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

type SmtpError = Error & {
  code?: string;
  response?: string;
  responseCode?: number;
  command?: string;
};
const transientTransportCodes = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "ETIMEDOUT",
  "ESOCKET",
  "EPIPE",
]);

function enhancedStatusCode(value: string | undefined) {
  return value?.match(/(?:^|[\s-])([245]\.\d{1,3}\.\d{1,3})(?=$|[\s-])/u)?.[1];
}

// A three-digit 550-554 response alone does not identify the failing party:
// it can describe a full mailbox, sender policy or unacceptable content. Only
// these standardized, permanent destination-address statuses are strong
// enough evidence to suppress the recipient automatically.
const permanentRecipientAddressStatuses = new Set([
  "5.1.1", // Bad destination mailbox address.
  "5.1.2", // Bad destination system address.
  "5.1.3", // Bad destination mailbox address syntax.
  "5.1.6", // Destination mailbox moved without forwarding address.
  "5.1.10", // Recipient domain explicitly publishes a null MX.
]);

function isPermanentRecipientAddressFailure(value: string | undefined) {
  return value !== undefined && permanentRecipientAddressStatuses.has(value);
}

function transportCode(value: string | undefined) {
  return value && /^[A-Z][A-Z0-9_-]{0,39}$/u.test(value)
    ? value
    : undefined;
}

export function classifySmtpError(error: unknown): EmailDeliveryResult {
  const smtp = error as SmtpError;
  const responseCode = Number.isInteger(smtp?.responseCode) ? smtp.responseCode : undefined;
  const providerCode = responseCode ? String(responseCode) : transportCode(smtp?.code);
  const enhancedCode = enhancedStatusCode(smtp?.response);
  if (responseCode === 535 || smtp?.code === "EAUTH") {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
      deliveryState: "configuration_error",
      providerCode,
      enhancedStatusCode: enhancedCode,
    };
  }
  if (responseCode && responseCode >= 400 && responseCode < 500) {
    return {
      delivered: false,
      reason: "provider_rejected",
      outcome: "retry",
      deliveryState: "temporary_failure",
      providerCode,
      enhancedStatusCode: enhancedCode,
    };
  }
  if (responseCode && responseCode >= 500) {
    return {
      delivered: false,
      reason: "provider_rejected",
      outcome: "failed",
      deliveryState: "permanent_rejection",
      providerCode,
      enhancedStatusCode: enhancedCode,
      recipientFailure: responseCode >= 550
        && responseCode <= 554
        && isPermanentRecipientAddressFailure(enhancedCode),
    };
  }
  const duringData = smtp?.command === "DATA" || smtp?.command === "DOT";
  if (duringData) {
    return {
      delivered: false,
      reason: "delivery_uncertain",
      outcome: "delivery_uncertain",
      deliveryState: "delivery_uncertain",
      providerCode,
      enhancedStatusCode: enhancedCode,
    };
  }
  if (smtp?.code && transientTransportCodes.has(smtp.code)) {
    return {
      delivered: false,
      reason: "provider_rejected",
      outcome: "retry",
      deliveryState: "temporary_failure",
      providerCode,
      enhancedStatusCode: enhancedCode,
    };
  }
  return {
    delivered: false,
    reason: "configuration_error",
    outcome: "failed",
    deliveryState: "configuration_error",
    providerCode,
    enhancedStatusCode: enhancedCode,
  };
}

export async function sendSmtpEmail(message: EmailMessage): Promise<EmailDeliveryResult> {
  const config = configuration();
  if (!config.enabled) {
    return {
      delivered: false,
      reason: "disabled",
      outcome: "failed",
      deliveryState: "disabled",
    };
  }
  if (!config.configured) {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
      deliveryState: "configuration_error",
    };
  }
  if (
    message.fromName !== config.fromName
    || message.fromEmail !== config.fromEmail
    || message.replyToEmail !== config.replyToEmail
  ) {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
      deliveryState: "configuration_error",
    };
  }
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
      return {
        delivered: false,
        reason: "delivery_uncertain",
        outcome: "delivery_uncertain",
        deliveryState: "delivery_uncertain",
      };
    }
    const response = typeof result.response === "string"
      ? result.response
      : undefined;
    return {
      delivered: true,
      deliveryState: "provider_accepted",
      providerMessageId,
      providerCode: response?.match(/^\s*(\d{3})(?:\s|$)/u)?.[1],
      enhancedStatusCode: enhancedStatusCode(response),
    };
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
