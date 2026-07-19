import { z } from "zod";

const recipientSchema = z.string().trim().email().max(320);
const renderedMessageSchema = z.object({
  jobId: z.string().uuid(),
  recipientEmail: recipientSchema,
  subject: z.string().trim().min(1).max(200),
  text: z.string().trim().min(1).max(20_000),
  html: z.string().trim().min(1).max(50_000),
  replyToEmail: z.string().trim().email().max(320),
}).strict();

export type SendGridDeliveryResult =
  | { delivered: true; providerMessageId: string }
  | { delivered: false; reason: "disabled" | "configuration_error" | "provider_error"; retryable: boolean };

function providerConfiguration() {
  const enabled = process.env.EMAIL_ENABLED === "true";
  if (!enabled) return { enabled: false as const };
  const apiKey = process.env.SENDGRID_API_KEY;
  const fromEmail = process.env.SENDGRID_FROM_EMAIL;
  if (!apiKey || !fromEmail || !recipientSchema.safeParse(fromEmail).success) return { enabled: true as const, configured: false as const };
  return { enabled: true as const, configured: true as const, apiKey, fromEmail };
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
  const replyToEmail = process.env.SENDGRID_REPLY_TO_EMAIL;
  const recipient = recipientSchema.safeParse(recipientEmail);
  const replyTo = recipientSchema.safeParse(replyToEmail);
  const rendered = z.object({
    subject: z.string().trim().min(1).max(200),
    text: z.string().trim().min(1).max(20_000),
    html: z.string().trim().min(1).max(50_000),
  }).strict().safeParse(message);
  if (!configuration.enabled) return { delivered: false as const, reason: "disabled" as const };
  if (!configuration.configured || !recipient.success || !replyTo.success || !rendered.success) {
    return { delivered: false as const, reason: "configuration_error" as const };
  }

  try {
    const response = await mailSend(configuration.apiKey, {
      personalizations: [{ to: [{ email: recipient.data }] }],
      from: { email: configuration.fromEmail, name: "Duindorp SV Tenueportaal" },
      reply_to: { email: replyTo.data },
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

export async function sendEmailJob(message: z.input<typeof renderedMessageSchema>): Promise<SendGridDeliveryResult> {
  const configuration = providerConfiguration();
  if (!configuration.enabled) return { delivered: false, reason: "disabled", retryable: true };
  if (!configuration.configured) return { delivered: false, reason: "configuration_error", retryable: false };
  const parsed = renderedMessageSchema.safeParse(message);
  if (!parsed.success) return { delivered: false, reason: "configuration_error", retryable: false };

  try {
    const response = await mailSend(configuration.apiKey, {
      personalizations: [{
        to: [{ email: parsed.data.recipientEmail }],
        custom_args: { email_job_id: parsed.data.jobId },
      }],
      from: { email: configuration.fromEmail, name: "Duindorp SV Tenueportaal" },
      ...(parsed.data.replyToEmail ? { reply_to: { email: parsed.data.replyToEmail } } : {}),
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
      return { delivered: false, reason: "provider_error", retryable: response.status === 408 || response.status === 429 || response.status >= 500 };
    }
    const providerMessageId = response.headers.get("x-message-id")?.trim();
    if (!providerMessageId) return { delivered: false, reason: "provider_error", retryable: true };
    return { delivered: true, providerMessageId };
  } catch {
    return { delivered: false, reason: "provider_error", retryable: true };
  }
}
