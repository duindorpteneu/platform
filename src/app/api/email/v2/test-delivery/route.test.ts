import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ send: vi.fn() }));
vi.mock("@/server/email/mail-v2-test-delivery", () => ({
  sendMailV2TestDelivery: mocks.send,
}));

import { POST } from "./route";

const requestId = "a3300000-0000-4000-8000-000000000001";
const correlationId = "a3300000-0000-4000-8000-000000000002";
const contentHash = "a".repeat(64);
const validBody = {
  requestId,
  templateKey: "package_complete",
  expectedContentHash: contentHash,
};

function request(body: BodyInit, headers: Record<string, string> = {}) {
  return new Request("https://tenue.example/api/email/v2/test-delivery", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": correlationId,
      "content-type": "application/json",
      ...headers,
    },
    body,
    ...(body instanceof ReadableStream ? { duplex: "half" as const } : {}),
  } as RequestInit & { duplex?: "half" });
}

describe("POST /api/email/v2/test-delivery", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.send.mockReset().mockResolvedValue({
      data: {
        deliveryId: "a3300000-0000-4000-8000-000000000003",
        status: "accepted",
        reused: false,
      },
      error: null,
    });
  });

  it("verstuurt alleen een strikt begrensde same-origin aanvraag", async () => {
    const response = await POST(request(JSON.stringify(validBody)));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.send).toHaveBeenCalledWith(
      validBody,
      correlationId,
      "https://tenue.example",
    );
  });

  it("weigert een ontvanger of vrije inhoud in de requestbody", async () => {
    const response = await POST(request(JSON.stringify({
      ...validBody,
      recipientEmail: "iemand@example.nl",
      html: "<p>Vrije inhoud</p>",
    })));

    expect(response.status).toBe(400);
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("blokkeert cross-site verzoeken vóór de service", async () => {
    const response = await POST(request(
      JSON.stringify(validBody),
      {
        origin: "https://evil.example",
        "sec-fetch-site": "cross-site",
      },
    ));

    expect(response.status).toBe(403);
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("vertaalt AAL2-weigering zonder databasecontext te lekken", async () => {
    mocks.send.mockResolvedValueOnce({
      data: null,
      error: { code: "42501", message: "gevoelige databasecontext" },
    });
    const response = await POST(request(JSON.stringify(validBody)));

    expect(response.status).toBe(403);
    expect(await response.text()).not.toContain("gevoelige databasecontext");
  });

  it("meldt een onzekere finalisatie zonder automatische tweede send", async () => {
    mocks.send.mockRejectedValueOnce(
      new Error("MAIL_V2_TEST_FINALIZE_UNCERTAIN"),
    );
    const response = await POST(request(JSON.stringify(validBody)));

    expect(response.status).toBe(503);
    expect(await response.text()).toContain("niet opnieuw verzonden");
    expect(mocks.send).toHaveBeenCalledTimes(1);
  });

  it("begrensd ook misleidend gechunkte requestbody's op vier KiB", async () => {
    const response = await POST(request(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(4_097));
          controller.close();
        },
      }),
      { "content-length": "1" },
    ));

    expect(response.status).toBe(413);
    expect(mocks.send).not.toHaveBeenCalled();
  });
});
