const MUTATION_METHODS = new Set(["POST", "PATCH", "DELETE"]);

export type BrowserMutationFailureCode =
  | "method_not_allowed"
  | "invalid_configuration"
  | "origin_required"
  | "origin_mismatch"
  | "host_required"
  | "host_mismatch"
  | "forwarded_host_mismatch"
  | "forwarded_proto_mismatch"
  | "fetch_metadata_required"
  | "cross_site_request"
  | "csrf_header_required";

export type BodyHeaderFailureCode =
  | "content_length_required"
  | "content_length_invalid"
  | "body_too_large"
  | "content_type_required"
  | "content_type_not_allowed"
  | "content_encoding_not_allowed";

export type BodyReadFailureCode =
  | "body_too_large"
  | "body_timeout"
  | "body_too_fragmented"
  | "body_stream_unavailable"
  | "body_stream_error"
  | "body_invalid_utf8"
  | "body_invalid_json";

type ValidationResult<TCode extends string> =
  | { ok: true }
  | { ok: false; code: TCode; status: 403 | 405 | 413 | 415 | 500 };

export class RequestBodyError extends Error {
  constructor(
    readonly code: BodyReadFailureCode,
    readonly status: 400 | 408 | 413,
  ) {
    super(code);
    this.name = "RequestBodyError";
  }
}

function singleForwardedValue(value: string | null) {
  if (!value) return null;
  const values = value.split(",").map((part) => part.trim()).filter(Boolean);
  return values.length === 1 ? values[0]!.toLowerCase() : "";
}

function canonicalOrigin(appBaseUrl: string) {
  try {
    const url = new URL(appBaseUrl);
    if (url.username || url.password || !["http:", "https:"].includes(url.protocol)) return null;
    return url;
  } catch {
    return null;
  }
}

export function validateBrowserMutation(
  request: Pick<Request, "method" | "headers">,
  appBaseUrl: string,
): ValidationResult<BrowserMutationFailureCode> {
  if (!MUTATION_METHODS.has(request.method.toUpperCase())) {
    return { ok: false, code: "method_not_allowed", status: 405 };
  }

  const canonical = canonicalOrigin(appBaseUrl);
  if (!canonical) return { ok: false, code: "invalid_configuration", status: 500 };

  const origin = request.headers.get("origin");
  if (!origin || origin === "null") return { ok: false, code: "origin_required", status: 403 };

  let requestOrigin: string;
  try {
    requestOrigin = new URL(origin).origin;
  } catch {
    return { ok: false, code: "origin_mismatch", status: 403 };
  }
  if (requestOrigin !== canonical.origin) return { ok: false, code: "origin_mismatch", status: 403 };

  const host = request.headers.get("host")?.trim().toLowerCase();
  if (!host) return { ok: false, code: "host_required", status: 403 };
  if (host !== canonical.host.toLowerCase()) return { ok: false, code: "host_mismatch", status: 403 };

  const forwardedHost = singleForwardedValue(request.headers.get("x-forwarded-host"));
  if (forwardedHost !== null && forwardedHost !== canonical.host.toLowerCase()) {
    return { ok: false, code: "forwarded_host_mismatch", status: 403 };
  }

  const forwardedProto = singleForwardedValue(request.headers.get("x-forwarded-proto"));
  if (forwardedProto !== null && `${forwardedProto}:` !== canonical.protocol) {
    return { ok: false, code: "forwarded_proto_mismatch", status: 403 };
  }

  const fetchSite = request.headers.get("sec-fetch-site")?.trim().toLowerCase();
  if (!fetchSite) return { ok: false, code: "fetch_metadata_required", status: 403 };
  if (fetchSite !== "same-origin") return { ok: false, code: "cross_site_request", status: 403 };
  if (request.headers.get("x-duindorp-csrf") !== "same-origin") return { ok: false, code: "csrf_header_required", status: 403 };

  return { ok: true };
}

export interface BodyHeaderOptions {
  allowedContentTypes: readonly string[];
  maxBytes: number;
  requireContentLength?: boolean;
  timeoutMs?: number;
  maxChunks?: number;
}

export interface BodyReadOptions {
  maxBytes: number;
  timeoutMs?: number;
  maxChunks?: number;
}

export const BODY_POLICIES = {
  jsonTiny: {
    allowedContentTypes: ["application/json"],
    maxBytes: 4_096,
    timeoutMs: 5_000,
    maxChunks: 512,
  },
  jsonSmall: {
    allowedContentTypes: ["application/json"],
    maxBytes: 10_000,
    timeoutMs: 5_000,
    maxChunks: 1_024,
  },
  jsonMedium: {
    allowedContentTypes: ["application/json"],
    maxBytes: 20_000,
    timeoutMs: 5_000,
    maxChunks: 2_048,
  },
  articleSeasonBulk: {
    allowedContentTypes: ["application/json"],
    maxBytes: 40_000,
    timeoutMs: 5_000,
    maxChunks: 4_096,
  },
  staffSession: {
    allowedContentTypes: ["application/json"],
    maxBytes: 40_960,
    timeoutMs: 5_000,
    maxChunks: 4_096,
  },
  jsonStandard: {
    allowedContentTypes: ["application/json"],
    maxBytes: 64 * 1_024,
    timeoutMs: 5_000,
    maxChunks: 4_096,
  },
  mailTemplate: {
    allowedContentTypes: ["application/json"],
    maxBytes: 96 * 1_024,
    timeoutMs: 5_000,
    maxChunks: 4_096,
  },
  emailBulk: {
    allowedContentTypes: ["application/json"],
    maxBytes: 256 * 1_024,
    timeoutMs: 10_000,
    maxChunks: 8_192,
  },
  sportlinkCsv: {
    allowedContentTypes: ["text/csv", "application/csv", "application/vnd.ms-excel"],
    maxBytes: 10 * 1_024 * 1_024,
    timeoutMs: 30_000,
    maxChunks: 16_384,
  },
  sendgridWebhook: {
    allowedContentTypes: ["application/json"],
    maxBytes: 1_000_000,
    timeoutMs: 10_000,
    maxChunks: 16_384,
  },
  mollieWebhook: {
    allowedContentTypes: ["application/x-www-form-urlencoded"],
    maxBytes: 10_000,
    timeoutMs: 5_000,
    maxChunks: 1_024,
  },
  empty: {
    maxBytes: 0,
    timeoutMs: 2_000,
    maxChunks: 1,
  },
} as const satisfies Record<string, BodyReadOptions & Partial<BodyHeaderOptions>>;

export function validateBodyHeaders(
  request: Pick<Request, "headers">,
  options: BodyHeaderOptions,
): ValidationResult<BodyHeaderFailureCode> {
  const contentLength = request.headers.get("content-length");
  if (!contentLength) {
    if (options.requireContentLength) return { ok: false, code: "content_length_required", status: 413 };
  } else if (!/^\d+$/.test(contentLength)) {
    return { ok: false, code: "content_length_invalid", status: 413 };
  } else if (Number(contentLength) > options.maxBytes) {
    return { ok: false, code: "body_too_large", status: 413 };
  }

  const rawContentType = request.headers.get("content-type");
  if (!rawContentType) return { ok: false, code: "content_type_required", status: 415 };
  const contentType = rawContentType.split(";", 1)[0]!.trim().toLowerCase();
  const allowed = options.allowedContentTypes.map((type) => type.toLowerCase());
  if (!allowed.includes(contentType)) return { ok: false, code: "content_type_not_allowed", status: 415 };

  const contentEncoding = request.headers.get("content-encoding")?.trim().toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    return { ok: false, code: "content_encoding_not_allowed", status: 415 };
  }

  return { ok: true };
}

function bodyReadError(code: BodyReadFailureCode) {
  if (code === "body_too_large" || code === "body_too_fragmented") {
    return new RequestBodyError(code, 413);
  }
  if (code === "body_timeout") return new RequestBodyError(code, 408);
  return new RequestBodyError(code, 400);
}

export async function readBoundedBody(
  request: Pick<Request, "body" | "bodyUsed">,
  options: BodyReadOptions,
) {
  const timeoutMs = options.timeoutMs ?? 5_000;
  const maxChunks = options.maxChunks ?? 16_384;
  if (!Number.isSafeInteger(options.maxBytes) || options.maxBytes < 0
    || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1
    || !Number.isSafeInteger(maxChunks) || maxChunks < 1) {
    throw new TypeError("Invalid bounded-body configuration");
  }
  if (request.bodyUsed) throw bodyReadError("body_stream_unavailable");
  if (!request.body) return new Uint8Array();

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  const startedAt = performance.now();
  let byteCount = 0;
  let chunkCount = 0;
  let completed = false;

  try {
    while (true) {
      const remainingMs = timeoutMs - (performance.now() - startedAt);
      if (remainingMs <= 0) throw bodyReadError("body_timeout");

      let timeout: ReturnType<typeof setTimeout> | undefined;
      let result: ReadableStreamReadResult<Uint8Array>;
      try {
        result = await Promise.race([
          reader.read(),
          new Promise<never>((_resolve, reject) => {
            timeout = setTimeout(() => reject(bodyReadError("body_timeout")), remainingMs);
          }),
        ]);
      } finally {
        if (timeout) clearTimeout(timeout);
      }

      if (result.done) {
        completed = true;
        break;
      }
      if (!(result.value instanceof Uint8Array)) throw bodyReadError("body_stream_error");

      chunkCount += 1;
      if (chunkCount > maxChunks) throw bodyReadError("body_too_fragmented");
      byteCount += result.value.byteLength;
      if (byteCount > options.maxBytes) throw bodyReadError("body_too_large");
      chunks.push(result.value);
    }
  } catch (error) {
    if (error instanceof RequestBodyError) throw error;
    throw bodyReadError("body_stream_error");
  } finally {
    if (!completed) {
      let cancelTimer: ReturnType<typeof setTimeout> | undefined;
      await Promise.race([
        reader.cancel().catch(() => undefined),
        new Promise<void>((resolve) => {
          cancelTimer = setTimeout(resolve, 50);
        }),
      ]);
      if (cancelTimer) clearTimeout(cancelTimer);
    }
    try { reader.releaseLock(); } catch { /* A hostile stream may keep a read pending after cancellation. */ }
  }

  const body = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

export async function readBoundedText(
  request: Pick<Request, "body" | "bodyUsed">,
  options: BodyReadOptions,
) {
  const body = await readBoundedBody(request, options);
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    throw bodyReadError("body_invalid_utf8");
  }
}

export async function readBoundedJson(
  request: Pick<Request, "body" | "bodyUsed">,
  options: BodyReadOptions,
): Promise<unknown> {
  const body = await readBoundedText(request, options);
  try {
    return JSON.parse(body) as unknown;
  } catch {
    throw bodyReadError("body_invalid_json");
  }
}
