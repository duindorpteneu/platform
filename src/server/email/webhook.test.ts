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
    const rawBody = JSON.stringify([
      { event: "open", sg_event_id: "ignored", sg_message_id: "message-0", timestamp: 1_784_376_000 },
      { event: "bounce", sg_event_id: "event-1", sg_message_id: "message-1", timestamp: 1_784_376_001 },
      { event: "bounce", sg_event_id: "event-1", sg_message_id: "message-1", timestamp: 1_784_376_001 },
      { event: "deferred", sg_event_id: "event-2", sg_message_id: "message-2", timestamp: "1784376002" },
    ]);
    expect(parseSendGridOperationalEvents(rawBody)).toEqual([
      { providerEventId: "event-1", providerMessageId: "message-1", eventType: "bounced", occurredAt: "2026-07-18T12:00:01.000Z" },
      { providerEventId: "event-2", providerMessageId: "message-2", eventType: "deferred", occurredAt: "2026-07-18T12:00:02.000Z" },
    ]);
  });

  it("rejects an operational event without provider identity", () => {
    expect(() => parseSendGridOperationalEvents('[{"event":"delivered","timestamp":1784376000}]')).toThrow("SENDGRID_EVENT_IDENTITY_INVALID");
  });

  it("matches the database boundary of at most 500 events", () => {
    const event = { event: "open", timestamp: 1_784_376_000 };
    expect(parseSendGridOperationalEvents(JSON.stringify(Array.from({ length: 500 }, () => event)))).toEqual([]);
    expect(() => parseSendGridOperationalEvents(JSON.stringify(Array.from({ length: 501 }, () => event)))).toThrow("SENDGRID_EVENT_BODY_INVALID");
  });
});
