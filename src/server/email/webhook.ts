import { createPublicKey, verify } from "node:crypto";
import { z } from "zod";

export const sendGridEventTypeSchema = z.enum(["delivered", "bounced", "deferred", "dropped", "failed"]);
export type SendGridEventType = z.infer<typeof sendGridEventTypeSchema>;

type SendGridEventIdentity = {
  deliveryAttemptId: string;
  providerEventId: string;
  providerMessageId: string | null;
  eventType: SendGridEventType;
  occurredAt: string;
};

export type SendGridOperationalEvent =
  | SendGridEventIdentity & {
      target: "email_job";
      emailJobId: string;
    }
  | SendGridEventIdentity & {
      target: "parent_otp";
    }
  | SendGridEventIdentity & {
      target: "mail_test";
      testDeliveryId: string;
    };

const eventEnvelopeSchema = z.object({
  event: z.string().min(1).max(80),
  delivery_kind: z.string().min(1).max(80).optional(),
  email_job_id: z.string().uuid().optional(),
  delivery_attempt_id: z.string().uuid().optional(),
  otp_delivery_attempt_id: z.string().uuid().optional(),
  test_delivery_id: z.string().uuid().optional(),
  sg_event_id: z.string().min(1).max(240).optional(),
  sg_message_id: z.string().min(1).max(240).optional(),
  timestamp: z.union([z.number().int().nonnegative(), z.string().regex(/^\d+$/)]).optional(),
}).passthrough();

function sendGridPublicKey(publicKey: string) {
  if (publicKey.includes("BEGIN PUBLIC KEY")) return createPublicKey(publicKey.replaceAll("\\n", "\n"));
  return createPublicKey({ key: Buffer.from(publicKey, "base64"), format: "der", type: "spki" });
}

export function verifySendGridSignature(
  rawBody: string | Uint8Array,
  timestamp: string | null,
  signature: string | null,
  publicKey: string,
) {
  if (!timestamp || !/^\d+$/.test(timestamp) || !signature || !publicKey) return false;
  try {
    const signedPayload = Buffer.concat([Buffer.from(timestamp, "utf8"), Buffer.from(rawBody)]);
    return verify("sha256", signedPayload, sendGridPublicKey(publicKey), Buffer.from(signature, "base64"));
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
  const unique = new Set<string>();
  const events: SendGridOperationalEvent[] = [];
  for (const envelope of envelopes.data) {
    const eventType = normalizeEventType(envelope.event);
    if (!eventType) continue;
    const hasQueuedIdentity = Boolean(
      envelope.email_job_id || envelope.delivery_attempt_id,
    );
    const hasOtpIdentity = Boolean(envelope.otp_delivery_attempt_id);
    const hasTestIdentity = Boolean(envelope.test_delivery_id);
    if (!hasQueuedIdentity && !hasOtpIdentity && !hasTestIdentity) {
      if (
        envelope.delivery_kind === "parent_otp"
        || envelope.delivery_kind === "admin_test"
      ) {
        throw new Error("SENDGRID_EVENT_IDENTITY_INVALID");
      }
      continue;
    }
    if (
      Number(hasQueuedIdentity)
        + Number(hasOtpIdentity)
        + Number(hasTestIdentity) > 1
    ) {
      throw new Error("SENDGRID_EVENT_IDENTITY_INVALID");
    }
    if (
      (hasQueuedIdentity && (
        !envelope.email_job_id
        || !envelope.delivery_attempt_id
        || envelope.delivery_kind === "parent_otp"
      ))
      || (hasOtpIdentity && envelope.delivery_kind !== "parent_otp")
      || (
        hasTestIdentity
        && envelope.delivery_kind !== "admin_test"
      )
      || !envelope.sg_event_id
      || (!envelope.sg_message_id && eventType !== "bounced")
      || envelope.timestamp === undefined
    ) {
      throw new Error("SENDGRID_EVENT_IDENTITY_INVALID");
    }
    const seconds = Number(envelope.timestamp);
    const occurredAt = new Date(seconds * 1_000);
    if (!Number.isFinite(seconds) || Number.isNaN(occurredAt.getTime())) throw new Error("SENDGRID_EVENT_TIMESTAMP_INVALID");
    const identity = {
      deliveryAttemptId: hasOtpIdentity
        ? envelope.otp_delivery_attempt_id!
        : hasTestIdentity
          ? envelope.test_delivery_id!
          : envelope.delivery_attempt_id!,
      providerEventId: envelope.sg_event_id,
      providerMessageId: envelope.sg_message_id ?? null,
      eventType,
      occurredAt: occurredAt.toISOString(),
    };
    const event: SendGridOperationalEvent = hasOtpIdentity
      ? { target: "parent_otp", ...identity }
      : hasTestIdentity
        ? {
            target: "mail_test",
            testDeliveryId: envelope.test_delivery_id!,
            ...identity,
          }
      : {
          target: "email_job",
          emailJobId: envelope.email_job_id!,
          ...identity,
        };
    const dedupeIdentity = JSON.stringify([
      event.target,
      event.providerEventId,
      event.target === "email_job" ? event.emailJobId : null,
      event.target === "mail_test" ? event.testDeliveryId : null,
      event.deliveryAttemptId,
      event.providerMessageId,
      event.eventType,
      event.occurredAt,
    ]);
    if (unique.has(dedupeIdentity)) continue;
    unique.add(dedupeIdentity);
    events.push(event);
  }
  return events;
}
