import { describe, expect, it } from "vitest";
import {
  readBoundedBody,
  readBoundedJson,
  readBoundedText,
  RequestBodyError,
  validateBodyHeaders,
  validateBrowserMutation,
} from "./request";

const canonical = "https://tenue.duindorpsv.nl";

function mutationRequest(overrides: { method?: string; headers?: Record<string, string> } = {}) {
  return new Request(`${canonical}/api/orders/save`, {
    method: overrides.method ?? "POST",
    headers: {
      host: "tenue.duindorpsv.nl",
      origin: canonical,
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      ...overrides.headers,
    },
  });
}

describe("browser mutation guard", () => {
  it.each([
    ["valid canonical request", {}, { ok: true }],
    ["valid trusted proxy headers", { headers: { "x-forwarded-host": "tenue.duindorpsv.nl", "x-forwarded-proto": "https" } }, { ok: true }],
    ["safe method", { method: "GET" }, { ok: false, code: "method_not_allowed", status: 405 }],
    ["missing origin", { headers: { origin: "" } }, { ok: false, code: "origin_required", status: 403 }],
    ["opaque origin", { headers: { origin: "null" } }, { ok: false, code: "origin_required", status: 403 }],
    ["same-site sibling", { headers: { origin: "https://leden.duindorpsv.nl" } }, { ok: false, code: "origin_mismatch", status: 403 }],
    ["foreign origin", { headers: { origin: "https://attacker.example" } }, { ok: false, code: "origin_mismatch", status: 403 }],
    ["missing host", { headers: { host: "" } }, { ok: false, code: "host_required", status: 403 }],
    ["spoofed host", { headers: { host: "attacker.example" } }, { ok: false, code: "host_mismatch", status: 403 }],
    ["spoofed forwarded host", { headers: { "x-forwarded-host": "attacker.example" } }, { ok: false, code: "forwarded_host_mismatch", status: 403 }],
    ["ambiguous forwarded host", { headers: { "x-forwarded-host": "tenue.duindorpsv.nl, attacker.example" } }, { ok: false, code: "forwarded_host_mismatch", status: 403 }],
    ["downgraded forwarded protocol", { headers: { "x-forwarded-proto": "http" } }, { ok: false, code: "forwarded_proto_mismatch", status: 403 }],
    ["missing fetch metadata", { headers: { "sec-fetch-site": "" } }, { ok: false, code: "fetch_metadata_required", status: 403 }],
    ["cross-site fetch", { headers: { "sec-fetch-site": "cross-site" } }, { ok: false, code: "cross_site_request", status: 403 }],
    ["same-site fetch", { headers: { "sec-fetch-site": "same-site" } }, { ok: false, code: "cross_site_request", status: 403 }],
    ["missing CSRF proof", { headers: { "x-duindorp-csrf": "" } }, { ok: false, code: "csrf_header_required", status: 403 }],
  ] as const)("handles %s", (_name, overrides, expected) => {
    expect(validateBrowserMutation(mutationRequest(overrides), canonical)).toEqual(expected);
  });

  it("normalizes default HTTPS ports but preserves non-default ports", () => {
    expect(validateBrowserMutation(mutationRequest(), "https://tenue.duindorpsv.nl:443/app")).toEqual({ ok: true });
    expect(validateBrowserMutation(mutationRequest(), "https://tenue.duindorpsv.nl:4443")).toMatchObject({ ok: false, code: "origin_mismatch" });
  });

  it("fails closed on invalid canonical configuration", () => {
    expect(validateBrowserMutation(mutationRequest(), "javascript:alert(1)")).toEqual({ ok: false, code: "invalid_configuration", status: 500 });
  });
});

describe("body header guard", () => {
  const options = { allowedContentTypes: ["application/json", "multipart/form-data"], maxBytes: 1_024, requireContentLength: true };

  it.each([
    ["valid JSON", { "content-length": "1024", "content-type": "application/json; charset=utf-8" }, { ok: true }],
    ["valid multipart", { "content-length": "500", "content-type": "multipart/form-data; boundary=secure" }, { ok: true }],
    ["missing length", { "content-type": "application/json" }, { ok: false, code: "content_length_required", status: 413 }],
    ["negative length", { "content-length": "-1", "content-type": "application/json" }, { ok: false, code: "content_length_invalid", status: 413 }],
    ["ambiguous length", { "content-length": "12, 13", "content-type": "application/json" }, { ok: false, code: "content_length_invalid", status: 413 }],
    ["oversized body", { "content-length": "1025", "content-type": "application/json" }, { ok: false, code: "body_too_large", status: 413 }],
    ["missing type", { "content-length": "10" }, { ok: false, code: "content_type_required", status: 415 }],
    ["wrong type", { "content-length": "10", "content-type": "text/plain" }, { ok: false, code: "content_type_not_allowed", status: 415 }],
    ["compressed body", { "content-length": "10", "content-type": "application/json", "content-encoding": "gzip" }, { ok: false, code: "content_encoding_not_allowed", status: 415 }],
  ] as const)("handles %s", (_name, headers, expected) => {
    expect(validateBodyHeaders(new Request(canonical, { headers }), options)).toEqual(expected);
  });

  it("can defer missing-length enforcement to a bounded streaming reader", () => {
    expect(validateBodyHeaders(new Request(canonical, { headers: { "content-type": "application/json" } }), {
      ...options,
      requireContentLength: false,
    })).toEqual({ ok: true });
  });
});

function chunkedRequest(chunks: Uint8Array[], headers: Record<string, string> = {}) {
  let index = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      const chunk = chunks[index];
      index += 1;
      if (chunk) controller.enqueue(chunk);
      else controller.close();
    },
  });
  return new Request(canonical, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body,
    duplex: "half",
  } as RequestInit & { duplex: "half" });
}

describe("bounded body reader", () => {
  const encoder = new TextEncoder();

  it("accepts a chunked body exactly at the byte limit without Content-Length", async () => {
    const request = chunkedRequest([encoder.encode('{"ok":'), encoder.encode("true}")]);
    await expect(readBoundedJson(request, { maxBytes: 11 })).resolves.toEqual({ ok: true });
  });

  it("rejects a chunked body after the actual bytes exceed the declared cap", async () => {
    const request = chunkedRequest(
      [encoder.encode("1234"), encoder.encode("5678")],
      { "content-length": "1" },
    );
    await expect(readBoundedBody(request, { maxBytes: 7 })).rejects.toMatchObject({
      code: "body_too_large",
      status: 413,
    });
  });

  it("rejects excessive tiny chunks independently of total bytes", async () => {
    const request = chunkedRequest([encoder.encode("a"), encoder.encode("b"), encoder.encode("c")]);
    await expect(readBoundedBody(request, { maxBytes: 10, maxChunks: 2 })).rejects.toMatchObject({
      code: "body_too_fragmented",
      status: 413,
    });
  });

  it("rejects a body that does not arrive within the total read deadline", async () => {
    const request = new Request(canonical, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: new ReadableStream<Uint8Array>({ pull() { return new Promise(() => undefined); } }),
      duplex: "half",
    } as RequestInit & { duplex: "half" });
    await expect(readBoundedText(request, { maxBytes: 10, timeoutMs: 10 })).rejects.toMatchObject({
      code: "body_timeout",
      status: 408,
    });
  });

  it("rejects malformed UTF-8 and JSON with typed safe errors", async () => {
    await expect(readBoundedText(chunkedRequest([new Uint8Array([0xc3, 0x28])]), { maxBytes: 2 }))
      .rejects.toEqual(expect.objectContaining({ code: "body_invalid_utf8", status: 400 }));
    await expect(readBoundedJson(chunkedRequest([encoder.encode("{")]), { maxBytes: 1 }))
      .rejects.toEqual(expect.objectContaining({ code: "body_invalid_json", status: 400 }));
  });

  it("refuses a previously consumed stream", async () => {
    const request = chunkedRequest([encoder.encode("{}")]);
    await request.text();
    await expect(readBoundedBody(request, { maxBytes: 10 })).rejects.toBeInstanceOf(RequestBodyError);
    await expect(readBoundedBody(request, { maxBytes: 10 })).rejects.toMatchObject({
      code: "body_stream_unavailable",
    });
  });

  it("bounds hostile stream cancellation after a read timeout", async () => {
    const request = new Request(canonical, {
      method: "POST",
      body: new ReadableStream<Uint8Array>({
        pull() { return new Promise(() => undefined); },
        cancel() { return new Promise(() => undefined); },
      }),
      duplex: "half",
    } as RequestInit & { duplex: "half" });
    const startedAt = Date.now();

    await expect(readBoundedBody(request, { maxBytes: 10, timeoutMs: 5 }))
      .rejects.toMatchObject({ code: "body_timeout", status: 408 });
    expect(Date.now() - startedAt).toBeLessThan(250);
  });

  it("maps an aborted or errored body stream to a safe typed error", async () => {
    const request = new Request(canonical, {
      method: "POST",
      body: new ReadableStream<Uint8Array>({
        start(controller) { controller.error(new Error("sensitive transport detail")); },
      }),
      duplex: "half",
    } as RequestInit & { duplex: "half" });

    await expect(readBoundedBody(request, { maxBytes: 10 }))
      .rejects.toMatchObject({ code: "body_stream_error", status: 400 });
  });

  it("treats invalid reader configuration as a programmer error", async () => {
    await expect(readBoundedBody(chunkedRequest([]), { maxBytes: -1 }))
      .rejects.toBeInstanceOf(TypeError);
  });
});
