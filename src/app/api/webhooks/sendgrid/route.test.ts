import { generateKeyPairSync, sign } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  rpc: vi.fn(),
  warn: vi.fn(),
}));

vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/security/logger", () => ({
  operationalLogger: { warn: mocks.warn },
}));

import { POST } from "./route";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const publicKeyDer = publicKey.export({ type: "spki", format: "der" }).toString("base64");

function signedRequest(rawBody: Uint8Array, timestamp = String(Math.floor(Date.now() / 1_000))) {
  const payload = Buffer.concat([Buffer.from(timestamp, "utf8"), Buffer.from(rawBody)]);
  const signature = sign("sha256", payload, privateKey).toString("base64");
  const requestBody = new Uint8Array(rawBody).buffer;
  return new Request("https://tenue.example/api/webhooks/sendgrid", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-twilio-email-event-webhook-signature": signature,
      "x-twilio-email-event-webhook-timestamp": timestamp,
    },
    body: requestBody,
  });
}

describe("POST /api/webhooks/sendgrid", () => {
  beforeEach(() => {
    process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY = publicKeyDer;
    mocks.rpc.mockReset().mockImplementation(
      async (name: string, args: { p_events?: unknown[] }) => ({
        data: name === "assert_sendgrid_events_ready_v1"
          ? { ready: args.p_events?.length ?? 0 }
          : { recorded: 1, ignored: 0, quarantined: 0 },
        error: null,
      }),
    );
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
    mocks.warn.mockReset();
  });

  it("verifieert de handtekening over de exacte UTF-8-bytes vóór parsing", async () => {
    const rawBody = new TextEncoder().encode(JSON.stringify([{
      event: "delivered",
      email_job_id: "11111111-1111-4111-8111-111111111111",
      delivery_attempt_id: "22222222-2222-4222-8222-222222222222",
      sg_event_id: "event-1",
      sg_message_id: "bericht-ü",
      timestamp: 1_785_680_000,
    }]));

    const response = await POST(signedRequest(rawBody));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      recorded: 1,
      ignored: 0,
      quarantined: 0,
    });
    expect(mocks.rpc).toHaveBeenCalledWith("record_sendgrid_events_v4", {
      p_events: [expect.objectContaining({
        delivery_attempt_id: "22222222-2222-4222-8222-222222222222",
        event_id: "event-1",
        provider_message_id: "bericht-ü",
      })],
    });
  });

  it("routeert een gemengde batch naar gescheiden queue- en OTP-ledgers", async () => {
    mocks.rpc.mockImplementation(async (
      name: string,
      args: { p_events?: unknown[] },
    ) => ({
      data: name === "assert_sendgrid_events_ready_v1"
        ? { ready: args.p_events?.length ?? 0 }
        : name === "record_sendgrid_events_v4"
          ? { recorded: 1, ignored: 0, quarantined: 0 }
          : { recorded: 0, ignored: 1, quarantined: 0 },
      error: null,
    }));
    const rawBody = new TextEncoder().encode(JSON.stringify([
      {
        event: "delivered",
        email_job_id: "11111111-1111-4111-8111-111111111111",
        delivery_attempt_id:
          "22222222-2222-4222-8222-222222222222",
        sg_event_id: "event-queue",
        sg_message_id: "message-queue",
        timestamp: 1_785_680_000,
      },
      {
        event: "delivered",
        delivery_kind: "parent_otp",
        otp_delivery_attempt_id:
          "33333333-3333-4333-8333-333333333333",
        sg_event_id: "event-otp",
        sg_message_id: "message-otp",
        timestamp: 1_785_680_000,
      },
    ]));
    const response = await POST(signedRequest(rawBody));
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      recorded: 1,
      ignored: 1,
      quarantined: 0,
    });
    expect(mocks.rpc).toHaveBeenNthCalledWith(
      3,
      "record_parent_otp_sendgrid_events_v3",
      {
        p_events: [expect.objectContaining({
          delivery_attempt_id:
            "33333333-3333-4333-8333-333333333333",
          event_id: "event-otp",
        })],
      },
    );
  });

  it("routeert een admin-testmail uitsluitend naar de testdelivery-ledger", async () => {
    const rawBody = new TextEncoder().encode(JSON.stringify([{
      event: "delivered",
      delivery_kind: "admin_test",
      test_delivery_id:
        "44444444-4444-4444-8444-444444444444",
      sg_event_id: "event-test",
      sg_message_id: "message-test",
      timestamp: 1_785_680_000,
    }]));
    const response = await POST(signedRequest(rawBody));
    expect(response.status).toBe(202);
    expect(mocks.rpc).toHaveBeenNthCalledWith(
      2,
      "record_mail_test_sendgrid_events_v4",
      {
        p_events: [{
          delivery_id:
            "44444444-4444-4444-8444-444444444444",
          event_id: "event-test",
          provider_message_id: "message-test",
          event_type: "delivered",
          occurred_at: "2026-08-02T14:13:20.000Z",
        }],
      },
    );
    expect(mocks.rpc).toHaveBeenCalledTimes(2);
  });

  it("stelt ook een testevent-race zonder serialization exception uit", async () => {
    mocks.rpc
      .mockResolvedValueOnce({ data: { ready: 1 }, error: null })
      .mockResolvedValueOnce({
        data: {
          recorded: 0,
          ignored: 0,
          quarantined: 0,
          pending: true,
        },
        error: null,
      });
    const rawBody = new TextEncoder().encode(JSON.stringify([{
      event: "bounce",
      delivery_kind: "admin_test",
      test_delivery_id:
        "44444444-4444-4444-8444-444444444444",
      sg_event_id: "event-test-before-acceptance",
      timestamp: 1_785_680_000,
    }]));

    const response = await POST(signedRequest(rawBody));

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    expect(mocks.rpc).toHaveBeenCalledTimes(2);
  });

  it("vraagt SendGrid om retry als de HTTP-acceptatie nog niet duurzaam is", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: {
        code: "40001",
        message: "SENDGRID_EVENT_ACCEPTANCE_PENDING",
      },
    });
    const rawBody = new TextEncoder().encode(JSON.stringify([{
      event: "delivered",
      email_job_id: "11111111-1111-4111-8111-111111111111",
      delivery_attempt_id: "22222222-2222-4222-8222-222222222222",
      sg_event_id: "event-before-acceptance",
      sg_message_id: "message-before-acceptance",
      timestamp: 1_785_680_000,
    }]));

    const response = await POST(signedRequest(rawBody));

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith(
      "assert_sendgrid_events_ready_v1",
      {
        p_events: [{
          target: "email_job",
          email_job_id: "11111111-1111-4111-8111-111111111111",
          delivery_attempt_id: "22222222-2222-4222-8222-222222222222",
          delivery_id: null,
        }],
      },
    );
    expect(mocks.warn).toHaveBeenCalledWith(
      "sendgrid.webhook_deferred",
      expect.objectContaining({
        code: "acceptance_pending",
        status: 503,
      }),
    );
  });

  it("vraagt zonder retrybare database-exception om retry bij een pending readiness", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { ready: 0 },
      error: null,
    });
    const rawBody = new TextEncoder().encode(JSON.stringify([{
      event: "delivered",
      email_job_id: "11111111-1111-4111-8111-111111111111",
      delivery_attempt_id: "22222222-2222-4222-8222-222222222222",
      sg_event_id: "event-before-acceptance-result",
      sg_message_id: "message-before-acceptance-result",
      timestamp: 1_785_680_000,
    }]));

    const response = await POST(signedRequest(rawBody));

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    expect(mocks.rpc).toHaveBeenCalledOnce();
    expect(mocks.warn).toHaveBeenCalledWith(
      "sendgrid.webhook_deferred",
      expect.objectContaining({
        code: "acceptance_pending",
        status: 503,
      }),
    );
  });

  it("weigert gewijzigde bytes ondanks een verder geldige envelop", async () => {
    const original = new TextEncoder().encode("[]");
    const request = signedRequest(original);
    const tampered = new Request(request.url, {
      method: "POST",
      headers: request.headers,
      body: "[ ]",
    });

    const response = await POST(tampered);

    expect(response.status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.warn).toHaveBeenCalledWith(
      "sendgrid.webhook_rejected",
      expect.objectContaining({
        code: "signature_invalid",
        status: 401,
      }),
    );
  });

  it("weigert een chunked payload boven de werkelijke bytelimiet vóór verificatie", async () => {
    const request = new Request("https://tenue.example/api/webhooks/sendgrid", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": "1",
        "x-twilio-email-event-webhook-signature": "invalid",
        "x-twilio-email-event-webhook-timestamp": String(Math.floor(Date.now() / 1_000)),
      },
      body: new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(1_000_001));
          controller.close();
        },
      }),
      duplex: "half",
    } as RequestInit & { duplex: "half" });

    const response = await POST(request);

    expect(response.status).toBe(413);
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.warn).toHaveBeenCalledWith(
      "sendgrid.webhook_rejected",
      expect.objectContaining({
        code: "body_read_failed",
        status: 413,
      }),
    );
  });
});
