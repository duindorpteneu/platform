import { describe, expect, it } from "vitest";
import { validateBodyHeaders, validateBrowserMutation } from "./request";

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
