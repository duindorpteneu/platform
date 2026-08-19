import type { z } from "zod";
import { operationalLogger } from "@/server/security/logger";
import { emailAddressSchema, mailTestEmailSchema, parentOtpEmailSchema, renderedEmailJobSchema, type EmailDeliveryResult, type EmailProviderHealth } from "../provider-contract";

type Identity = { jobId?: string; deliveryAttemptId?: string };
type SesSender = (input: unknown, options: unknown) => Promise<{ MessageId?: string }>;
let testSender: SesSender | null = null;
export function setSesSenderForTests(sender: SesSender | null) { testSender = sender; }
function configuration() {
  const enabled = process.env.EMAIL_ENABLED === "true";
  if (!enabled) return { enabled: false as const };
  const region = process.env.AWS_REGION?.trim();
  const accessKeyId = process.env.AWS_ACCESS_KEY_ID?.trim();
  const secretAccessKey = process.env.AWS_SECRET_ACCESS_KEY;
  const fromName = process.env.SES_FROM_NAME?.trim();
  const fromEmail = process.env.SES_FROM_EMAIL?.trim();
  const replyToEmail = process.env.SES_REPLY_TO_EMAIL?.trim();
  const configurationSet = process.env.SES_CONFIGURATION_SET?.trim();
  if (!region || !/^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u.test(region) || !accessKeyId || !secretAccessKey || !fromName || /[\r\n]/u.test(fromName) || fromName.length < 3 || fromName.length > 120 || !emailAddressSchema.safeParse(fromEmail).success || !emailAddressSchema.safeParse(replyToEmail).success || !configurationSet || configurationSet.length > 64 || !/^[A-Za-z0-9_-]+$/u.test(configurationSet)) return { enabled: true as const, configured: false as const };
  return { enabled: true as const, configured: true as const, region, accessKeyId, secretAccessKey, fromName, fromEmail: fromEmail!, replyToEmail: replyToEmail!, configurationSet };
}
export function sesRuntimeHealth(): EmailProviderHealth {
  const c = configuration();
  const runtimeValueValid = ["true", "false"].includes(process.env.EMAIL_ENABLED?.trim() ?? "");
  const configured = c.enabled && c.configured && Boolean(process.env.SES_SNS_TOPIC_ARN?.trim()) && (process.env.CRON_SECRET?.length ?? 0) >= 16;
  return { runtimeValueValid, runtimeEnabled: process.env.EMAIL_ENABLED === "true", provider: "ses", providerConfigured: configured, credentialsValid: c.enabled && c.configured, keyFingerprintMatches: c.enabled && c.configured };
}
function normalizeCode(error: unknown) { const raw = typeof error === "object" && error && "name" in error ? String(error.name) : "UnknownError"; return raw.replace(/[^A-Za-z0-9_.-]/gu, "_").slice(0, 64).toLowerCase(); }
function mapError(error: unknown): Exclude<EmailDeliveryResult, { delivered: true }> {
  const code = normalizeCode(error);
  const status = typeof error === "object" && error && "$metadata" in error ? Number((error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode) : 0;
  if (/timeout|abort|network|socket|econn|unknownendpoint/u.test(code)) return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain", providerCode: code };
  if (/toomanyrequests|throttl/u.test(code) || status === 429) return { delivered: false, reason: "provider_rejected", outcome: "retry", providerCode: code };
  if (/credentials|unrecognizedclient|invalidsignature|expiredtoken|accessdenied|account.*suspend|sendingpaused|mailfromdomainnotverified|notfound/u.test(code)) return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode: code };
  if (/messagerejected|badrequest/u.test(code)) return { delivered: false, reason: "provider_rejected", outcome: "failed", providerCode: code };
  if (status >= 500 || /serviceunavailable|internalfailure/u.test(code)) return { delivered: false, reason: "provider_rejected", outcome: "retry", providerCode: code };
  return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain", providerCode: code };
}
async function send(message: { recipientEmail: string; subject: string; text: string; html: string; fromName: string; fromEmail: string; replyToEmail: string }, tags: { Name: string; Value: string }[], identity: Identity): Promise<EmailDeliveryResult> {
  const c = configuration();
  if (!c.enabled) return { delivered: false, reason: "disabled", outcome: identity.jobId ? "retry" : "failed" };
  if (!c.configured || message.fromName !== c.fromName || message.fromEmail !== c.fromEmail || message.replyToEmail !== c.replyToEmail) return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode: "ses_configuration_invalid" };
  try {
    const input = { Destination: { ToAddresses: [message.recipientEmail] }, FromEmailAddress: `"${message.fromName.replaceAll('"', "'")}" <${message.fromEmail}>`, ReplyToAddresses: [message.replyToEmail], Content: { Simple: { Subject: { Data: message.subject, Charset: "UTF-8" }, Body: { Text: { Data: message.text, Charset: "UTF-8" }, Html: { Data: message.html, Charset: "UTF-8" } } } }, ConfigurationSetName: c.configurationSet, EmailTags: tags };
    let response: { MessageId?: string };
    if (testSender) response = await testSender(input, { abortSignal: AbortSignal.timeout(10_000) });
    else {
      const sdkModule = "@aws-sdk/client-sesv2";
      const { SESv2Client, SendEmailCommand } = await import(sdkModule) as { SESv2Client: new (input: unknown) => { send(command: unknown, options: unknown): Promise<{ MessageId?: string }> }; SendEmailCommand: new (input: unknown) => unknown };
      const client = new SESv2Client({ region: c.region, credentials: { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey }, maxAttempts: 3 });
      response = await client.send(new SendEmailCommand(input), { abortSignal: AbortSignal.timeout(10_000) });
    }
    const providerMessageId = response.MessageId?.trim();
    if (!providerMessageId) return { delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain", providerCode: "ses_message_id_missing" };
    return { delivered: true, providerMessageId };
  } catch (error) {
    const result = mapError(error);
    operationalLogger.warn("email.provider_send_failed", { provider: "ses", operation: "send_email", providerCode: result.providerCode, status: typeof error === "object" && error && "$metadata" in error ? Number((error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode) : undefined, retryable: result.outcome === "retry", ...identity });
    return result;
  }
}
export async function sendEmailJob(input: z.input<typeof renderedEmailJobSchema>) { const p = renderedEmailJobSchema.safeParse(input); if (!p.success) return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode: "message_invalid" } as const; return send(p.data, [{ Name: "delivery_kind", Value: "email_job" }, { Name: "email_job_id", Value: p.data.jobId }, { Name: "delivery_attempt_id", Value: p.data.deliveryAttemptId }], { jobId: p.data.jobId, deliveryAttemptId: p.data.deliveryAttemptId }); }
export async function sendParentOtpV2Email(input: z.input<typeof parentOtpEmailSchema>) { const p = parentOtpEmailSchema.safeParse(input); if (!p.success) return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode: "message_invalid" } as const; return send(p.data, [{ Name: "delivery_kind", Value: "parent_otp" }, { Name: "otp_delivery_attempt_id", Value: p.data.deliveryAttemptId }], { deliveryAttemptId: p.data.deliveryAttemptId }); }
export async function sendMailV2TestEmail(input: z.input<typeof mailTestEmailSchema>) { const p = mailTestEmailSchema.safeParse(input); const recipient = emailAddressSchema.safeParse(process.env.SES_SMOKE_RECIPIENT); if (!p.success || !recipient.success) return { delivered: false, reason: "configuration_error", outcome: "failed", providerCode: "message_invalid" } as const; return send({ ...p.data, recipientEmail: recipient.data }, [{ Name: "delivery_kind", Value: "admin_test" }, { Name: "test_delivery_id", Value: p.data.testDeliveryId }], { deliveryAttemptId: p.data.testDeliveryId }); }
