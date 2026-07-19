import { createPublicKey, verify } from "node:crypto";
import { z } from "zod";

export const sendGridEventTypeSchema = z.enum(["delivered", "bounced", "deferred", "dropped", "failed"]);
export type SendGridEventType = z.infer<typeof sendGridEventTypeSchema>;

export type SendGridOperationalEvent = {
  emailJobId: string;
  providerEventId: string;
  providerMessageId: string | null;
  eventType: SendGridEventType;
  occurredAt: string;
};

const eventEnvelopeSchema = z.object({
  event: z.string().min(1).max(80),
  email_job_id: z.string().uuid().optional(),
  sg_event_id: z.string().min(1).max(240).optional(),
  sg_message_id: z.string().min(1).max(240).optional(),
  timestamp: z.union([z.number().int().nonnegative(), z.string().regex(/^\d+$/)]).optional(),
}).passthrough();

function sendGridPublicKey(publicKey: string) {
  if (publicKey.includes("BEGIN PUBLIC KEY")) return createPublicKey(publicKey.replaceAll("\\n", "\n"));
  return createPublicKey({ key: Buffer.from(publicKey, "base64"), format: "der", type: "spki" });
}

export function verifySendGridSignature(rawBody: string, timestamp: string | null, signature: string | null, publicKey: string) {
  if (!timestamp || !/^\d+$/.test(timestamp) || !signature || !publicKey) return false;
  try {
    return verify("sha256", Buffer.from(timestamp + rawBody), sendGridPublicKey(publicKey), Buffer.from(signature, "base64"));
  } catch {
    return false;
  }
}

export function isFreshSendGridTimestamp(timestamp: string | null, now = Date.now(), maximumSkewMs = 5 * 60 * 1_000) {
  if (!timestamp || !/^\d+$/.test(timestamp)) return false;
  const signedAt = Number(timestamp) * 1_000;
  return Number.isSafeInteger(signedAt) && Math.abs(now - signedAt) <= maximumSkewMs;
}

function normalizeEventType(event: string): SendGridEventType | null {
  if (event === "bounce" || event === "bounced") return "bounced";
  return sendGridEventTypeSchema.safeParse(event).success ? event as SendGridEventType : null;
}

export function parseSendGridOperationalEvents(rawBody: string): SendGridOperationalEvent[] {
  let body: unknown;
  try { body = JSON.parse(rawBody); } catch { throw new Error("SENDGRID_EVENT_BODY_INVALID"); }
  const envelopes = z.array(eventEnvelopeSchema).max(500).safeParse(body);
  if (!envelopes.success) throw new Error("SENDGRID_EVENT_BODY_INVALID");
  const unique = new Map<string, SendGridOperationalEvent>();
  for (const envelope of envelopes.data) {
    const eventType = normalizeEventType(envelope.event);
    if (!eventType) continue;
    // Direct OTP and controlled provider-smoke messages do not have a durable
    // queue job. Their signed operational events are valid but not correlatable.
    if (!envelope.email_job_id) continue;
    if (!envelope.sg_event_id || envelope.timestamp === undefined) throw new Error("SENDGRID_EVENT_IDENTITY_INVALID");
    const seconds = Number(envelope.timestamp);
    const occurredAt = new Date(seconds * 1_000);
    if (!Number.isFinite(seconds) || Number.isNaN(occurredAt.getTime())) throw new Error("SENDGRID_EVENT_TIMESTAMP_INVALID");
    unique.set(envelope.sg_event_id, {
      emailJobId: envelope.email_job_id,
      providerEventId: envelope.sg_event_id,
      providerMessageId: envelope.sg_message_id ?? null,
      eventType,
      occurredAt: occurredAt.toISOString(),
    });
  }
  return [...unique.values()];
}
