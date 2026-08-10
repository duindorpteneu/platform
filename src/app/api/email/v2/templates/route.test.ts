import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  publish: vi.fn(),
  save: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-workspace", () => ({
  publishMailV2Template: mocks.publish,
  saveMailV2TemplateDraft: mocks.save,
}));

import { POST } from "./route";

const revisionId = "66000000-0000-4000-8000-000000000001";
const contentHash = "a".repeat(64);
const correlationId = "66000000-0000-4000-8000-000000000002";
const validDraft = {
  action: "save" as const,
  templateKey: "partial_pickup" as const,
  expectedHash: null,
  internalName: "Deelafhaling",
  subjectSource: "Deelafhaling voor {{member_first_name}}",
  preheaderSource: "Bekijk wat is afgehaald.",
  bodyTipTap: {
    type: "doc" as const,
    content: [{
      type: "paragraph" as const,
      content: [{ type: "text" as const, text: "Beste ouder" }],
    }],
  },
};

function request(body: BodyInit, contentLength?: string) {
  const headers: Record<string, string> = {
    origin: "https://tenue.example",
    host: "tenue.example",
    "sec-fetch-site": "same-origin",
    "x-duindorp-csrf": "same-origin",
    "x-correlation-id": correlationId,
    "content-type": "application/json",
  };
  if (contentLength) headers["content-length"] = contentLength;
  return new Request("https://tenue.example/api/email/v2/templates", {
    method: "POST",
    headers,
    body,
    ...(body instanceof ReadableStream ? { duplex: "half" as const } : {}),
  } as RequestInit & { duplex?: "half" });
}

describe("POST /api/email/v2/templates", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.save.mockReset().mockResolvedValue({
      data: {
        revisionId,
        revision: 1,
        status: "draft",
        contentHash,
        templateKey: "partial_pickup",
      },
      error: null,
    });
    mocks.publish.mockReset().mockResolvedValue({
      data: {
        revisionId,
        revision: 1,
        status: "published",
        contentHash,
        templateKey: "partial_pickup",
      },
      error: null,
    });
  });

  it("stuurt alleen het strikt gevalideerde TipTap-contract door", async () => {
    const response = await POST(request(JSON.stringify(validDraft)));

    expect(response.status).toBe(200);
    expect(mocks.save).toHaveBeenCalledWith(
      validDraft,
      correlationId,
    );
    expect(mocks.publish).not.toHaveBeenCalled();
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("weigert onbekende editor-nodes vóór databaseautorisatie", async () => {
    const response = await POST(request(JSON.stringify({
      ...validDraft,
      bodyTipTap: {
        type: "doc",
        content: [{ type: "image", attrs: { src: "https://evil.invalid/x" } }],
      },
    })));

    expect(response.status).toBe(400);
    expect(mocks.save).not.toHaveBeenCalled();
  });

  it("vertaalt autorisatie en optimistic-concurrency zonder databasecontext te lekken", async () => {
    mocks.publish.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "gevoelige interne context" },
    });
    const stale = await POST(request(JSON.stringify({
      action: "publish",
      revisionId,
      expectedHash: contentHash,
    })));
    expect(stale.status).toBe(409);
    expect(await stale.text()).not.toContain("gevoelige interne context");

    mocks.publish.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    const denied = await POST(request(JSON.stringify({
      action: "publish",
      revisionId,
      expectedHash: contentHash,
    })));
    expect(denied.status).toBe(403);
  });

  it("weigert een misleidende content-length zodra chunked bytes 96 KiB overschrijden", async () => {
    const response = await POST(request(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(96 * 1_024 + 1));
          controller.close();
        },
      }),
      "1",
    ));

    expect(response.status).toBe(413);
    expect(mocks.save).not.toHaveBeenCalled();
  });
});
