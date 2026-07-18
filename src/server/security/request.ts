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
  | "content_type_not_allowed";

type ValidationResult<TCode extends string> =
  | { ok: true }
  | { ok: false; code: TCode; status: 403 | 405 | 413 | 415 | 500 };

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
}

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

  return { ok: true };
}
