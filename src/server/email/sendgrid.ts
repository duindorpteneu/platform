import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const recipientSchema = z.string().trim().email().max(320);
const renderedMessageSchema = z.object({
  jobId: z.string().uuid(),
  deliveryAttemptId: z.string().uuid(),
  recipientEmail: recipientSchema,
  subject: z.string().trim().min(1).max(200),
  text: z.string().trim().min(1).max(20_000),
  html: z.string().trim().min(1).max(50_000),
  fromName: z.string().trim().min(3).max(120).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  fromEmail: z.string().trim().email().max(320),
  replyToEmail: z.string().trim().email().max(320),
}).strict();

const parentOtpV2MessageSchema = renderedMessageSchema
  .omit({ jobId: true })
  .strict();

const mailV2TestMessageSchema = renderedMessageSchema
  .omit({ jobId: true, deliveryAttemptId: true, recipientEmail: true })
  .extend({ testDeliveryId: z.string().uuid() })
  .strict();

export type SendGridDeliveryResult =
  | { delivered: true; providerMessageId: string }
  | {
      delivered: false;
      reason: "disabled" | "configuration_error" | "provider_rejected" | "delivery_uncertain";
      outcome: "retry" | "failed" | "delivery_uncertain";
    };

function providerConfiguration() {
  const enabled = process.env.EMAIL_ENABLED === "true";
  if (!enabled) return { enabled: false as const };
  const apiKey = process.env.SENDGRID_API_KEY;
  const fromName = process.env.SENDGRID_FROM_NAME?.trim();
  const fromEmail = process.env.SENDGRID_FROM_EMAIL;
  const replyToEmail = process.env.SENDGRID_REPLY_TO_EMAIL;
  if (
    !apiKey
    || !fromName
    || fromName.length < 3
    || fromName.length > 120
    || /[\r\n]/u.test(fromName)
    || !sendGridKeyFingerprintMatches(apiKey)
    || !recipientSchema.safeParse(fromEmail).success
    || !recipientSchema.safeParse(replyToEmail).success
  ) {
    return { enabled: true as const, configured: false as const };
  }
  return {
    enabled: true as const,
    configured: true as const,
    apiKey,
    fromName,
    fromEmail: recipientSchema.parse(fromEmail),
    replyToEmail: recipientSchema.parse(replyToEmail),
  };
}

function sendGridKeyFingerprintMatches(apiKey: string | undefined) {
  const expectedFingerprint =
    process.env.SENDGRID_API_KEY_FINGERPRINT?.trim().toLowerCase();
  if (
    !apiKey
    || !expectedFingerprint
    || !/^[a-f0-9]{64}$/u.test(expectedFingerprint)
  ) {
    return false;
  }
  const actual = createHash("sha256").update(apiKey).digest();
  const expected = Buffer.from(expectedFingerprint, "hex");
  return expected.length === actual.length
    && timingSafeEqual(actual, expected);
}

export function sendGridRuntimeHealth() {
  const runtimeValue = process.env.EMAIL_ENABLED?.trim();
  const runtimeValueValid = runtimeValue === "true"
    || runtimeValue === "false";
  const runtimeEnabled = runtimeValue === "true";
  const apiKey = process.env.SENDGRID_API_KEY;
  const fromName = process.env.SENDGRID_FROM_NAME?.trim();
  const providerConfigured = Boolean(
    apiKey?.startsWith("SG.")
    && fromName
    && fromName.length >= 3
    && fromName.length <= 120
    && !/[\r\n]/u.test(fromName)
    && recipientSchema.safeParse(
      process.env.SENDGRID_FROM_EMAIL,
    ).success
    && recipientSchema.safeParse(
      process.env.SENDGRID_REPLY_TO_EMAIL,
    ).success
    && process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY?.trim()
    && (process.env.CRON_SECRET?.length ?? 0) >= 16
  );
  return {
    runtimeValueValid,
    runtimeEnabled,
    providerConfigured,
    keyFingerprintMatches: sendGridKeyFingerprintMatches(apiKey),
  };
}

async function mailSend(apiKey: string, body: Record<string, unknown>) {
  const apiBaseUrl = process.env.SENDGRID_API_BASE_URL === "https://api.eu.sendgrid.com"
    ? "https://api.eu.sendgrid.com"
    : "https://api.sendgrid.com";
  return fetch(`${apiBaseUrl}/v3/mail/send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
}

export async function sendParentOtpEmail(recipientEmail: string, message: { subject: string; text: string; html: string }) {
  const configuration = providerConfiguration();
  const recipient = recipientSchema.safeParse(recipientEmail);
  const rendered = z.object({
    subject: z.string().trim().min(1).max(200),
    text: z.string().trim().min(1).max(20_000),
    html: z.string().trim().min(1).max(50_000),
  }).strict().safeParse(message);
  if (!configuration.enabled) return { delivered: false as const, reason: "disabled" as const };
  if (!configuration.configured || !recipient.success || !rendered.success) {
    return { delivered: false as const, reason: "configuration_error" as const };
  }

  try {
    const response = await mailSend(configuration.apiKey, {
      personalizations: [{ to: [{ email: recipient.data }] }],
      from: {
        email: configuration.fromEmail,
        name: configuration.fromName,
      },
      reply_to: { email: configuration.replyToEmail },
      subject: rendered.data.subject,
      content: [
        { type: "text/plain", value: rendered.data.text },
        { type: "text/html", value: rendered.data.html },
      ],
      tracking_settings: { click_tracking: { enable: false, enable_text: false }, open_tracking: { enable: false } },
    });
    if (!response.ok) return { delivered: false as const, reason: "provider_error" as const };
    return { delivered: true as const };
  } catch {
    return { delivered: false as const, reason: "provider_error" as const };
  }
}

export async function sendParentOtpV2Email(
  message: z.input<typeof parentOtpV2MessageSchema>,
): Promise<SendGridDeliveryResult> {
  const configuration = providerConfiguration();
  if (!configuration.enabled) {
    return {
      delivered: false,
      reason: "disabled",
      outcome: "failed",
    };
  }
  if (!configuration.configured) {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
    };
  }
  const parsed = parentOtpV2MessageSchema.safeParse(message);
  if (
    !parsed.success
    || parsed.data.fromName !== configuration.fromName
    || parsed.data.fromEmail !== configuration.fromEmail
    || parsed.data.replyToEmail !== configuration.replyToEmail
  ) {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
    };
  }

  try {
    const response = await mailSend(configuration.apiKey, {
      personalizations: [{
        to: [{ email: parsed.data.recipientEmail }],
        custom_args: {
          delivery_kind: "parent_otp",
          otp_delivery_attempt_id: parsed.data.deliveryAttemptId,
        },
      }],
      from: {
        email: parsed.data.fromEmail,
        name: parsed.data.fromName,
      },
      reply_to: { email: parsed.data.replyToEmail },
      subject: parsed.data.subject,
      content: [
        { type: "text/plain", value: parsed.data.text },
        { type: "text/html", value: parsed.data.html },
      ],
      tracking_settings: {
        click_tracking: { enable: false, enable_text: false },
        open_tracking: { enable: false },
        subscription_tracking: { enable: false },
      },
    });
    if (!response.ok) {
      if (response.status === 408 || response.status >= 500) {
        return {
          delivered: false,
          reason: "delivery_uncertain",
          outcome: "delivery_uncertain",
        };
      }
      return {
        delivered: false,
        reason: "provider_rejected",
        outcome: "failed",
      };
    }
    const providerMessageId =
      response.headers.get("x-message-id")?.trim();
    if (!providerMessageId) {
      return {
        delivered: false,
        reason: "delivery_uncertain",
        outcome: "delivery_uncertain",
      };
    }
    return { delivered: true, providerMessageId };
  } catch {
    return {
      delivered: false,
      reason: "delivery_uncertain",
      outcome: "delivery_uncertain",
    };
  }
}

export async function sendMailV2TestEmail(
  message: z.input<typeof mailV2TestMessageSchema>,
): Promise<SendGridDeliveryResult> {
  const configuration = providerConfiguration();
  if (!configuration.enabled) {
    return { delivered: false, reason: "disabled", outcome: "failed" };
  }
  if (!configuration.configured) {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
    };
  }
  const recipient = recipientSchema.safeParse(
    process.env.SENDGRID_SMOKE_RECIPIENT,
  );
  const parsed = mailV2TestMessageSchema.safeParse(message);
  if (
    !recipient.success
    || !parsed.success
    || parsed.data.fromName !== configuration.fromName
    || parsed.data.fromEmail !== configuration.fromEmail
    || parsed.data.replyToEmail !== configuration.replyToEmail
  ) {
    return {
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
    };
  }

  try {
    const response = await mailSend(configuration.apiKey, {
      personalizations: [{
        to: [{ email: recipient.data }],
        custom_args: {
          delivery_kind: "admin_test",
          test_delivery_id: parsed.data.testDeliveryId,
        },
      }],
      from: {
        email: parsed.data.fromEmail,
        name: parsed.data.fromName,
      },
      reply_to: { email: parsed.data.replyToEmail },
      subject: parsed.data.subject,
      headers: {
        "X-Duindorp-Acceptance":
          parsed.data.testDeliveryId,
      },
      content: [
        { type: "text/plain", value: parsed.data.text },
        { type: "text/html", value: parsed.data.html },
      ],
      tracking_settings: {
        click_tracking: { enable: false, enable_text: false },
        open_tracking: { enable: false },
        subscription_tracking: { enable: false },
      },
    });
    if (!response.ok) {
      if (response.status === 408 || response.status >= 500) {
        return {
          delivered: false,
          reason: "delivery_uncertain",
          outcome: "delivery_uncertain",
        };
      }
      return {
        delivered: false,
        reason: "provider_rejected",
        outcome: response.status === 429 ? "retry" : "failed",
      };
    }
    const providerMessageId = response.headers.get("x-message-id")?.trim();
    if (!providerMessageId) {
      return {
        delivered: false,
        reason: "delivery_uncertain",
        outcome: "delivery_uncertain",
      };
    }
    return { delivered: true, providerMessageId };
  } catch {
    return {
      delivered: false,
      reason: "delivery_uncertain",
      outcome: "delivery_uncertain",
    };
  }
}

export async function sendEmailJob(message: z.input<typeof renderedMessageSchema>): Promise<SendGridDeliveryResult> {
  const configuration = providerConfiguration();
  if (!configuration.enabled) return { delivered: false, reason: "disabled", outcome: "retry" };
  if (!configuration.configured) return { delivered: false, reason: "configuration_error", outcome: "failed" };
  const parsed = renderedMessageSchema.safeParse(message);
  if (
    !parsed.success
    || parsed.data.fromName !== configuration.fromName
    || parsed.data.fromEmail !== configuration.fromEmail
    || parsed.data.replyToEmail !== configuration.replyToEmail
  ) {
    return { delivered: false, reason: "configuration_error", outcome: "failed" };
  }

  try {
    const response = await mailSend(configuration.apiKey, {
      personalizations: [{
        to: [{ email: parsed.data.recipientEmail }],
        custom_args: {
          email_job_id: parsed.data.jobId,
          delivery_attempt_id: parsed.data.deliveryAttemptId,
        },
      }],
      from: {
        email: parsed.data.fromEmail,
        name: parsed.data.fromName,
      },
      reply_to: { email: parsed.data.replyToEmail },
      subject: parsed.data.subject,
      content: [
        { type: "text/plain", value: parsed.data.text },
        { type: "text/html", value: parsed.data.html },
      ],
      tracking_settings: {
        click_tracking: { enable: false, enable_text: false },
        open_tracking: { enable: false },
        subscription_tracking: { enable: false },
      },
    });
    if (!response.ok) {
      if (response.status === 408 || response.status >= 500) {
        return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" };
      }
      return {
        delivered: false,
        reason: "provider_rejected",
        outcome: response.status === 429 ? "retry" : "failed",
      };
    }
    const providerMessageId = response.headers.get("x-message-id")?.trim();
    if (!providerMessageId) return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" };
    return { delivered: true, providerMessageId };
  } catch {
    return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" };
  }
}
