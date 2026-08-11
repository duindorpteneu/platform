const knownRemoteCodes = new Set([
  "22023",
  "42501",
  "PGRST106",
  "PGRST202",
]);

const knownProbeScopes = new Set([
  "ACCEPTANCE_CLEANUP",
  "ACCEPTANCE_PARENT_OTP",
  "ACCEPTANCE_PREPARE",
  "ACCEPTANCE_STATE",
  "ACTION_ITEMS_ASSIGN",
  "ACTION_ITEMS_DISMISS",
  "ACTION_ITEMS_GET",
  "ACTION_ITEMS_RESOLVE",
  "ACTION_ITEMS_START",
  "DELIVERY_NOTIFICATION_CONFIRM",
  "DELIVERY_NOTIFICATION_GET",
  "FULFILMENT_COMMIT_V3",
  "HEALTH_V12",
  "MAIL_TEST_FINALIZE",
  "MAIL_TEST_PREPARE",
  "PACKAGE_CHANGE_APPLY",
  "PACKAGE_CHANGE_PREFLIGHT",
  "PARENT_WORKSPACE_V5",
  "QR_CANDIDATES",
  "QR_EXCHANGE_V2",
  "QR_EXPIRE_GRANTS",
  "QR_REGISTER",
  "RELEASE_FEATURES_ACTIVATE",
  "RELEASE_FEATURES_GET",
  "RELEASE_FEATURES_PAUSE",
  "SAVED_VIEWS_APPLY",
  "SAVED_VIEWS_DELETE",
  "SAVED_VIEWS_GET",
  "SAVED_VIEWS_SAVE",
  "STAFF_CONTEXT",
  "STAFF_RECOVERY_REVOKE",
  "STAFF_REVOKE",
  "STAFF_SESSION",
  "VERSION",
]);

const timeoutCodes = new Set([
  "ETIMEDOUT",
  "UND_ERR_BODY_TIMEOUT",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_HEADERS_TIMEOUT",
]);
const dnsCodes = new Set(["EAI_AGAIN", "EAI_FAIL", "EAI_NONAME", "ENOTFOUND"]);
const tlsCodes = new Set([
  "CERT_HAS_EXPIRED",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "ERR_TLS_CERT_ALTNAME_INVALID",
  "ERR_TLS_HANDSHAKE_TIMEOUT",
  "SELF_SIGNED_CERT_IN_CHAIN",
  "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
]);
const connectCodes = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "EHOSTUNREACH",
  "ENETDOWN",
  "ENETUNREACH",
  "EPIPE",
  "UND_ERR_SOCKET",
]);

export class PostgrestProbeError extends Error {
  constructor(code) {
    const match = /^HTTP_([A-Z0-9_]+)_([1-5][0-9]{2})_([A-Z0-9]+)$/.exec(code);
    const trustedHttpCode = match
      && knownProbeScopes.has(match[1])
      && (match[3] === "UNKNOWN" || knownRemoteCodes.has(match[3]));
    if (code !== "RESPONSE_INVALID" && !trustedHttpCode) {
      throw new Error("POSTGREST_PROBE_CODE_INVALID");
    }
    super(code);
    this.name = "PostgrestProbeError";
    this.code = code;
  }
}

export function createPostgrestHttpError(scope, status, remoteCode) {
  if (!knownProbeScopes.has(scope) || !Number.isInteger(status) || status < 100 || status > 599) {
    throw new Error("POSTGREST_PROBE_HTTP_INPUT_INVALID");
  }
  return new PostgrestProbeError(
    `HTTP_${scope}_${status}_${safeRemoteCode(remoteCode)}`,
  );
}

export function safeRemoteCode(value) {
  return typeof value === "string" && knownRemoteCodes.has(value)
    ? value
    : "UNKNOWN";
}

function collectErrorMetadata(error) {
  const queue = [error];
  const seen = new Set();
  const names = new Set();
  const codes = new Set();

  while (queue.length > 0 && seen.size < 16) {
    const candidate = queue.shift();
    if ((!candidate || typeof candidate !== "object") || seen.has(candidate)) continue;
    seen.add(candidate);

    if (typeof candidate.name === "string") names.add(candidate.name);
    if (typeof candidate.code === "string") codes.add(candidate.code);
    if (candidate.cause && typeof candidate.cause === "object") queue.push(candidate.cause);
    if (Array.isArray(candidate.errors)) queue.push(...candidate.errors);
  }

  return { codes, names };
}

export function classifyPostgrestProbeError(error) {
  if (error instanceof PostgrestProbeError) return error.code;

  const { codes, names } = collectErrorMetadata(error);
  if (
    names.has("AbortError")
    || names.has("TimeoutError")
    || [...codes].some((code) => timeoutCodes.has(code))
  ) return "REQUEST_TIMEOUT";
  if ([...codes].some((code) => dnsCodes.has(code))) return "REQUEST_DNS_FAILED";
  if ([...codes].some((code) => tlsCodes.has(code))) return "REQUEST_TLS_FAILED";
  if ([...codes].some((code) => connectCodes.has(code))) return "REQUEST_CONNECT_FAILED";
  return "REQUEST_FAILED";
}
