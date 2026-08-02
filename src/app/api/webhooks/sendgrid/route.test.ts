import { generateKeyPairSync, sign } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));

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
    mocks.rpc.mockReset().mockResolvedValue({ data: { recorded: 1, ignored: 0 }, error: null });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("verifieert de handtekening over de exacte UTF-8-bytes vóór parsing", async () => {
    const rawBody = new TextEncoder().encode(JSON.stringify([{
      event: "delivered",
      email_job_id: "11111111-1111-4111-8111-111111111111",
      sg_event_id: "event-1",
      sg_message_id: "bericht-ü",
      timestamp: 1_785_680_000,
    }]));

    const response = await POST(signedRequest(rawBody));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ recorded: 1, ignored: 0 });
    expect(mocks.rpc).toHaveBeenCalledWith("record_sendgrid_events", {
      p_events: [expect.objectContaining({
        event_id: "event-1",
        provider_message_id: "bericht-ü",
      })],
    });
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
  });
});
