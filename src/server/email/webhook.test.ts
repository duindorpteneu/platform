import { generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import { isFreshSendGridTimestamp, parseSendGridOperationalEvents, verifySendGridSignature } from "@/server/email/webhook";

describe("SendGrid event webhook", () => {
  it("rejects stale or future signed-request timestamps", () => {
    const now = Date.parse("2026-07-18T12:00:00Z");
    expect(isFreshSendGridTimestamp(String(now / 1_000), now)).toBe(true);
    expect(isFreshSendGridTimestamp(String((now - 301_000) / 1_000), now)).toBe(false);
    expect(isFreshSendGridTimestamp(String((now + 301_000) / 1_000), now)).toBe(false);
  });
  it("verifies the timestamp plus unmodified raw body", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const rawBody = '[{"event":"delivered"}]';
    const timestamp = "1784376000";
    const signature = sign("sha256", Buffer.from(timestamp + rawBody), privateKey).toString("base64");
    const der = publicKey.export({ type: "spki", format: "der" }).toString("base64");
    expect(verifySendGridSignature(rawBody, timestamp, signature, der)).toBe(true);
    expect(verifySendGridSignature(rawBody + " ", timestamp, signature, der)).toBe(false);
  });

  it("keeps only operational events, maps bounce and deduplicates", () => {
    const jobId = "11111111-1111-4111-8111-111111111111";
    const deliveryAttemptId = "22222222-2222-4222-8222-222222222222";
    const rawBody = JSON.stringify([
      { event: "open", sg_event_id: "ignored", sg_message_id: "message-0", timestamp: 1_784_376_000 },
      { event: "bounce", email_job_id: jobId, delivery_attempt_id: deliveryAttemptId, sg_event_id: "event-1", sg_message_id: "message-1", timestamp: 1_784_376_001 },
      { event: "bounce", email_job_id: jobId, delivery_attempt_id: deliveryAttemptId, sg_event_id: "event-1", sg_message_id: "message-1", timestamp: 1_784_376_001 },
      { event: "deferred", email_job_id: jobId, delivery_attempt_id: deliveryAttemptId, sg_event_id: "event-2", sg_message_id: "message-1", timestamp: "1784376002" },
    ]);
    expect(parseSendGridOperationalEvents(rawBody)).toEqual([
      { target: "email_job", emailJobId: jobId, deliveryAttemptId, providerEventId: "event-1", providerMessageId: "message-1", eventType: "bounced", occurredAt: "2026-07-18T12:00:01.000Z" },
      { target: "email_job", emailJobId: jobId, deliveryAttemptId, providerEventId: "event-2", providerMessageId: "message-1", eventType: "deferred", occurredAt: "2026-07-18T12:00:02.000Z" },
    ]);
  });

  it("rejects an operational event without provider identity", () => {
    expect(parseSendGridOperationalEvents('[{"event":"delivered","timestamp":1784376000}]')).toEqual([]);
    expect(() => parseSendGridOperationalEvents('[{"event":"delivered","email_job_id":"11111111-1111-4111-8111-111111111111","timestamp":1784376000}]')).toThrow("SENDGRID_EVENT_IDENTITY_INVALID");
  });

  it("herkent een expliciet attempt-gebonden OTP-event", () => {
    const deliveryAttemptId =
      "33333333-3333-4333-8333-333333333333";
    expect(parseSendGridOperationalEvents(JSON.stringify([{
      event: "delivered",
      delivery_kind: "parent_otp",
      otp_delivery_attempt_id: deliveryAttemptId,
      sg_event_id: "otp-event-1",
      sg_message_id: "otp-message-1",
      timestamp: 1_784_376_003,
    }]))).toEqual([{
      target: "parent_otp",
      deliveryAttemptId,
      providerEventId: "otp-event-1",
      providerMessageId: "otp-message-1",
      eventType: "delivered",
      occurredAt: "2026-07-18T12:00:03.000Z",
    }]);
  });

  it("weigert gemengde of gedeeltelijke queue/OTP-identiteiten", () => {
    const shared = {
      event: "delivered",
      delivery_kind: "parent_otp",
      otp_delivery_attempt_id:
        "33333333-3333-4333-8333-333333333333",
      sg_event_id: "otp-event-1",
      sg_message_id: "otp-message-1",
      timestamp: 1_784_376_003,
    };
    expect(() => parseSendGridOperationalEvents(JSON.stringify([{
      ...shared,
      email_job_id: "11111111-1111-4111-8111-111111111111",
      delivery_attempt_id:
        "22222222-2222-4222-8222-222222222222",
    }]))).toThrow("SENDGRID_EVENT_IDENTITY_INVALID");
    expect(() => parseSendGridOperationalEvents(JSON.stringify([{
      ...shared,
      otp_delivery_attempt_id: undefined,
    }]))).toThrow("SENDGRID_EVENT_IDENTITY_INVALID");
  });

  it("preserves a contradictory duplicate event ID for database quarantine", () => {
    const emailJobId = "11111111-1111-4111-8111-111111111111";
    const deliveryAttemptId = "22222222-2222-4222-8222-222222222222";
    const shared = {
      email_job_id: emailJobId,
      delivery_attempt_id: deliveryAttemptId,
      sg_event_id: "collision",
      sg_message_id: "message-1",
      timestamp: 1_784_376_001,
    };
    expect(parseSendGridOperationalEvents(JSON.stringify([
      { ...shared, event: "delivered" },
      { ...shared, event: "bounce" },
      { ...shared, event: "bounce" },
    ]))).toHaveLength(2);
  });

  it("matches the database boundary of at most 500 events", () => {
    const event = { event: "open", timestamp: 1_784_376_000 };
    expect(parseSendGridOperationalEvents(JSON.stringify(Array.from({ length: 500 }, () => event)))).toEqual([]);
    expect(() => parseSendGridOperationalEvents(JSON.stringify(Array.from({ length: 501 }, () => event)))).toThrow("SENDGRID_EVENT_BODY_INVALID");
  });
});
