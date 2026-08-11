import { createHmac, timingSafeEqual } from "node:crypto";
import rawContract from "../../../deploy/edge-body-probe-contract.json";

const markerHeader = "x-duindorp-edge-body-probe";
const timestampHeader = "x-duindorp-edge-body-probe-timestamp";
const nonceHeader = "x-duindorp-edge-body-probe-nonce";
const bytesHeader = "x-duindorp-edge-body-probe-bytes";
const signatureHeader = "x-duindorp-edge-body-probe-signature";
const environmentHeader = "x-duindorp-edge-body-probe-environment";
const releaseHeader = "x-duindorp-edge-body-probe-release";
const resultHeader = "x-duindorp-edge-body-probe-result";
const proofHeaders = Object.freeze([
  markerHeader,
  timestampHeader,
  nonceHeader,
  bytesHeader,
  signatureHeader,
  environmentHeader,
  releaseHeader,
  resultHeader,
]);

export type EdgeBodyProbeName =
  | "standard-api"
  | "email-bulk"
  | "sendgrid-webhook"
  | "sportlink-import";

type ProbeContract = Readonly<{
  name: EdgeBodyProbeName;
  path: string;
  maxBytes: number;
}>;

function loadContract() {
  if (rawContract.version !== "v1"
    || !Number.isSafeInteger(rawContract.freshnessSeconds)
    || rawContract.freshnessSeconds < 10
    || rawContract.freshnessSeconds > 300
    || !Array.isArray(rawContract.probes)) {
    throw new Error("EDGE_BODY_PROBE_CONTRACT_INVALID");
  }
  const expectedNames: EdgeBodyProbeName[] = [
    "standard-api",
    "email-bulk",
    "sendgrid-webhook",
    "sportlink-import",
  ];
  const entries = expectedNames.map((name) => {
    const matches = rawContract.probes.filter((probe) => probe.name === name);
    const probe = matches[0];
    if (matches.length !== 1
      || !probe
      || !probe.path.startsWith("/api/")
      || !Number.isSafeInteger(probe.maxBytes)
      || probe.maxBytes < 1) {
      throw new Error("EDGE_BODY_PROBE_CONTRACT_INVALID");
    }
    return [name, Object.freeze({ name, path: probe.path, maxBytes: probe.maxBytes })] as const;
  });
  if (rawContract.probes.length !== entries.length) {
    throw new Error("EDGE_BODY_PROBE_CONTRACT_INVALID");
  }
  return Object.freeze(Object.fromEntries(entries)) as Readonly<Record<EdgeBodyProbeName, ProbeContract>>;
}

export const EDGE_BODY_PROBE_CONTRACT = loadContract();

export function edgeBodyProbeSigningPayload(input: {
  version: string;
  timestamp: string;
  nonce: string;
  name: EdgeBodyProbeName;
  host: string;
  path: string;
  environment: string;
  releaseSha: string;
  bytes: number;
}) {
  return [
    `duindorp-edge-body-probe:${input.version}`,
    "POST",
    input.host,
    input.path,
    input.environment,
    input.releaseSha,
    String(input.bytes),
    input.timestamp,
    input.nonce,
    input.name,
  ].join("\n");
}

function emptyResponse(status: 204 | 401 | 422 | 503, result?: string) {
  const headers = new Headers({ "Cache-Control": "no-store" });
  if (result) headers.set(resultHeader, result);
  return new Response(null, { status, headers });
}

function validSignature(actual: string, expected: string) {
  if (!/^[a-f0-9]{64}$/.test(actual)) return false;
  const actualBytes = Buffer.from(actual, "hex");
  const expectedBytes = Buffer.from(expected, "hex");
  return actualBytes.length === expectedBytes.length
    && timingSafeEqual(actualBytes, expectedBytes);
}

function singleProxyHeader(value: string | null) {
  if (!value) return null;
  const values = value.split(",").map((part) => part.trim().toLowerCase()).filter(Boolean);
  return values.length === 1 ? values[0]! : null;
}

function publicRequestHost(headers: Headers, appBaseUrl: string | undefined) {
  let applicationUrl: URL;
  try { applicationUrl = new URL(appBaseUrl ?? ""); }
  catch { return null; }
  if (applicationUrl.username
    || applicationUrl.password
    || !["http:", "https:"].includes(applicationUrl.protocol)) return null;

  const expectedHost = applicationUrl.host.toLowerCase();
  const expectedProtocol = applicationUrl.protocol.slice(0, -1).toLowerCase();
  const host = singleProxyHeader(headers.get("host"));
  const forwardedHost = singleProxyHeader(headers.get("x-forwarded-host"));
  const forwardedProtocol = singleProxyHeader(headers.get("x-forwarded-proto"));
  if (host !== expectedHost
    || forwardedHost !== expectedHost
    || forwardedProtocol !== expectedProtocol) return null;
  return expectedHost;
}

async function drainExactBody(request: Request, expectedBytes: number) {
  if (request.bodyUsed || !request.body) return false;
  const reader = request.body.getReader();
  const startedAt = performance.now();
  const timeoutMs = 20_000;
  const maxChunks = 16_384;
  let byteCount = 0;
  let chunkCount = 0;
  let completed = false;

  try {
    while (true) {
      const remainingMs = timeoutMs - (performance.now() - startedAt);
      if (remainingMs <= 0) return false;
      let timeout: ReturnType<typeof setTimeout> | undefined;
      let result: ReadableStreamReadResult<Uint8Array>;
      try {
        result = await Promise.race([
          reader.read(),
          new Promise<never>((_resolve, reject) => {
            timeout = setTimeout(() => reject(new Error("EDGE_BODY_PROBE_TIMEOUT")), remainingMs);
          }),
        ]);
      } finally {
        if (timeout) clearTimeout(timeout);
      }
      if (result.done) {
        completed = true;
        break;
      }
      if (!(result.value instanceof Uint8Array)) return false;
      chunkCount += 1;
      byteCount += result.value.byteLength;
      if (chunkCount > maxChunks || byteCount > expectedBytes) return false;
    }
  } catch {
    return false;
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
    try { reader.releaseLock(); } catch { /* Een afgebroken proxy-stream kan de lock vasthouden. */ }
  }
  return byteCount === expectedBytes;
}

export async function handleEdgeBodyProbe(request: Request, name: EdgeBodyProbeName) {
  const marker = request.headers.get(markerHeader);
  const hasAnyProofHeader = proofHeaders.some((header) => request.headers.has(header));
  if (!hasAnyProofHeader) return null;
  if (marker === null) return emptyResponse(401);

  const contract = EDGE_BODY_PROBE_CONTRACT[name];
  const secret = process.env.CRON_SECRET;
  if (!secret || secret.length < 16) return emptyResponse(503);
  if (marker !== rawContract.version || request.method !== "POST") return emptyResponse(401);

  const url = new URL(request.url);
  const verifiedHost = publicRequestHost(request.headers, process.env.APP_BASE_URL);
  if (!verifiedHost
    || url.pathname !== contract.path
    || url.search !== "") return emptyResponse(401);
  if (request.headers.get("content-length") !== null
    || request.headers.get("content-type") !== "application/octet-stream"
    || request.headers.get("content-encoding") !== null) {
    return emptyResponse(401);
  }

  const timestamp = request.headers.get(timestampHeader) ?? "";
  const nonce = request.headers.get(nonceHeader) ?? "";
  const rawBytes = request.headers.get(bytesHeader) ?? "";
  const signature = request.headers.get(signatureHeader) ?? "";
  const environment = request.headers.get(environmentHeader) ?? "";
  const releaseSha = request.headers.get(releaseHeader) ?? "";
  if (!/^\d{10}$/.test(timestamp)
    || !/^[a-f0-9]{64}$/.test(nonce)
    || !/^\d{1,8}$/.test(rawBytes)
    || !["staging", "production"].includes(environment)
    || !/^[a-f0-9]{40}$/.test(releaseSha)) {
    return emptyResponse(401);
  }
  if (environment !== process.env.APP_ENVIRONMENT
    || releaseSha !== process.env.RELEASE_SHA) return emptyResponse(401);

  const requestedBytes = Number(rawBytes);
  if (![contract.maxBytes, contract.maxBytes + 1].includes(requestedBytes)) {
    return emptyResponse(401);
  }
  const ageSeconds = Math.abs(Math.floor(Date.now() / 1_000) - Number(timestamp));
  if (ageSeconds > rawContract.freshnessSeconds) return emptyResponse(401);

  const expectedSignature = createHmac("sha256", secret)
    .update(edgeBodyProbeSigningPayload({
      version: rawContract.version,
      timestamp,
      nonce,
      name,
      host: verifiedHost,
      path: contract.path,
      environment,
      releaseSha,
      bytes: requestedBytes,
    }))
    .digest("hex");
  if (!validSignature(signature, expectedSignature)) return emptyResponse(401);

  const drained = await drainExactBody(request, requestedBytes);
  if (!drained) return emptyResponse(422);
  return emptyResponse(204, "application-reached");
}
