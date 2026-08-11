import { spawn } from "node:child_process";
import { createServer, request as createUpstreamRequest } from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";
import rawContract from "../../deploy/edge-body-probe-contract.json" with { type: "json" };

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "expect",
  "keep-alive",
  "proxy-connection",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);
const DEFAULT_MAX_CHUNKS = 16_384;

function loadLimits() {
  const probes = Object.fromEntries(
    rawContract.probes.map((probe) => [probe.name, probe.maxBytes]),
  );
  for (const name of [
    "standard-api",
    "email-bulk",
    "sendgrid-webhook",
    "sportlink-import",
  ]) {
    if (!Number.isSafeInteger(probes[name]) || probes[name] < 1) {
      throw new Error("BODY_GATEWAY_CONTRACT_INVALID");
    }
  }
  return Object.freeze(probes);
}

const LIMITS = loadLimits();

const GROUP_POLICIES = Object.freeze({
  "standard-api": Object.freeze({
    bodyTimeoutMs: 5_000,
    maxBufferedRequests: 32,
  }),
  "email-bulk": Object.freeze({
    bodyTimeoutMs: 10_000,
    maxBufferedRequests: 4,
  }),
  "sendgrid-webhook": Object.freeze({
    bodyTimeoutMs: 10_000,
    maxBufferedRequests: 4,
  }),
  "sportlink-import": Object.freeze({
    bodyTimeoutMs: 30_000,
    maxBufferedRequests: 2,
  }),
});

function bodyGroupForUrl(rawUrl) {
  let pathname;
  try {
    pathname = new URL(rawUrl || "/", "http://runtime.invalid").pathname;
  } catch {
    return "standard-api";
  }
  if (
    pathname === "/api/imports/uploads"
    || pathname === "/api/imports/preview"
    || pathname === "/api/imports/commit"
  ) {
    return "sportlink-import";
  }
  if (pathname === "/api/webhooks/sendgrid") {
    return "sendgrid-webhook";
  }
  if (
    pathname === "/api/email/bulk"
    || pathname === "/api/email/v2/campaigns"
  ) {
    return "email-bulk";
  }
  return "standard-api";
}

export function bodyLimitForUrl(rawUrl) {
  return LIMITS[bodyGroupForUrl(rawUrl)];
}

function oneHeader(value) {
  if (Array.isArray(value)) return value.length === 1 ? value[0] : "";
  return value ?? "";
}

function requestBodyContract(request, maxBytes) {
  const contentLength = oneHeader(request.headers["content-length"]);
  const transferEncoding = oneHeader(request.headers["transfer-encoding"])
    .trim().toLowerCase();
  if (contentLength && transferEncoding) {
    return { ok: false, status: 400 };
  }
  if (contentLength) {
    if (!/^\d+$/u.test(contentLength)) return { ok: false, status: 400 };
    const declaredBytes = Number(contentLength);
    if (!Number.isSafeInteger(declaredBytes)) {
      return { ok: false, status: 400 };
    }
    if (declaredBytes > maxBytes) return { ok: false, status: 413 };
    return { ok: true, hasBody: declaredBytes > 0, chunked: false };
  }
  if (transferEncoding && transferEncoding !== "chunked") {
    return { ok: false, status: 400 };
  }
  return {
    ok: true,
    hasBody: transferEncoding === "chunked",
    chunked: transferEncoding === "chunked",
  };
}

function closeWithStatus(request, response, status) {
  if (response.headersSent || response.destroyed) return;
  response.once("finish", () => request.socket.destroy());
  response.writeHead(status, {
    "Cache-Control": "no-store",
    Connection: "close",
    "Content-Length": "0",
  });
  response.end();
  request.pause();
}

function collectBody(request, maxBytes, options) {
  return new Promise((resolve, reject) => {
    const body = Buffer.allocUnsafe(maxBytes);
    let bytes = 0;
    let chunkCount = 0;
    let settled = false;
    const finish = (error, body) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request.off("data", onData);
      request.off("end", onEnd);
      request.off("aborted", onAborted);
      request.off("error", onError);
      if (error) reject(error);
      else resolve(body);
    };
    const fail = (status) => finish(Object.assign(
      new Error("BODY_GATEWAY_REQUEST_REJECTED"),
      { status },
    ));
    const onData = (chunk) => {
      if (!Buffer.isBuffer(chunk)) return fail(400);
      chunkCount += 1;
      const nextBytes = bytes + chunk.length;
      if (chunkCount > options.maxChunks || nextBytes > maxBytes) {
        return fail(413);
      }
      chunk.copy(body, bytes);
      bytes = nextBytes;
    };
    const onEnd = () => finish(null, body.subarray(0, bytes));
    const onAborted = () => fail(400);
    const onError = () => fail(400);
    const timer = setTimeout(() => fail(408), options.bodyTimeoutMs);
    timer.unref?.();
    request.on("data", onData);
    request.once("end", onEnd);
    request.once("aborted", onAborted);
    request.once("error", onError);
  });
}

function connectionHeaderNames(headers) {
  const value = oneHeader(headers.connection);
  if (!value) return new Set();
  return new Set(value.split(",").map((name) => name.trim().toLowerCase())
    .filter((name) => /^[!#$%&'*+.^_`|~0-9a-z-]+$/u.test(name)));
}

function forwardedRequestHeaders(headers, chunked) {
  const forwarded = {};
  const connectionHeaders = connectionHeaderNames(headers);
  for (const [name, rawValue] of Object.entries(headers)) {
    if (
      HOP_BY_HOP_HEADERS.has(name)
      || connectionHeaders.has(name)
      || rawValue === undefined
    ) continue;
    forwarded[name] = rawValue;
  }
  if (chunked) {
    delete forwarded["content-length"];
    forwarded["transfer-encoding"] = "chunked";
  }
  return forwarded;
}

function forwardedResponseHeaders(headers) {
  const forwarded = {};
  const connectionHeaders = connectionHeaderNames(headers);
  for (const [name, rawValue] of Object.entries(headers)) {
    if (
      HOP_BY_HOP_HEADERS.has(name)
      || connectionHeaders.has(name)
      || rawValue === undefined
    ) continue;
    forwarded[name] = rawValue;
  }
  return forwarded;
}

function proxyBufferedRequest(
  clientRequest,
  clientResponse,
  body,
  chunked,
  options,
  releaseSlot,
) {
  let slotReleased = false;
  const release = () => {
    if (slotReleased) return;
    slotReleased = true;
    releaseSlot();
  };
  const upstreamRequest = createUpstreamRequest({
    hostname: options.upstreamHost,
    port: options.upstreamPort,
    path: clientRequest.url || "/",
    method: clientRequest.method,
    headers: forwardedRequestHeaders(clientRequest.headers, chunked),
    timeout: options.upstreamTimeoutMs,
  }, (upstreamResponse) => {
    if (clientResponse.destroyed) {
      upstreamResponse.destroy();
      return;
    }
    clientResponse.writeHead(
      upstreamResponse.statusCode ?? 502,
      forwardedResponseHeaders(upstreamResponse.headers),
    );
    upstreamResponse.once("aborted", () => clientResponse.destroy());
    upstreamResponse.once("error", () => clientResponse.destroy());
    upstreamResponse.pipe(clientResponse);
  });
  upstreamRequest.once("finish", release);
  upstreamRequest.once("timeout", () => {
    upstreamRequest.destroy(new Error("BODY_GATEWAY_UPSTREAM_TIMEOUT"));
  });
  upstreamRequest.once("error", (error) => {
    release();
    const code = typeof error?.code === "string"
      && /^[A-Z0-9_]{1,64}$/u.test(error.code)
      ? error.code
      : "UPSTREAM_ERROR";
    console.error(JSON.stringify({
      event: "body_limit_gateway_upstream_error",
      code,
    }));
    if (!clientResponse.headersSent && !clientResponse.destroyed) {
      clientResponse.writeHead(502, {
        "Cache-Control": "no-store",
        "Content-Length": "0",
      });
      clientResponse.end();
    } else {
      clientResponse.destroy();
    }
  });
  clientResponse.once("close", () => {
    if (!clientResponse.writableEnded) upstreamRequest.destroy();
  });
  upstreamRequest.end(body);
}

export function createBodyLimitGateway(rawOptions = {}) {
  const options = {
    upstreamHost: rawOptions.upstreamHost ?? "127.0.0.1",
    upstreamPort: rawOptions.upstreamPort ?? 3_001,
    bodyTimeoutMs:
      rawOptions.bodyTimeoutMs,
    upstreamTimeoutMs:
      rawOptions.upstreamTimeoutMs ?? 60_000,
    maxBufferedRequests:
      rawOptions.maxBufferedRequests,
    maxChunks: rawOptions.maxChunks ?? DEFAULT_MAX_CHUNKS,
  };
  if (
    options.upstreamHost !== "127.0.0.1"
    || !Number.isSafeInteger(options.upstreamPort)
    || options.upstreamPort < 1
    || options.upstreamPort > 65_535
    || (options.bodyTimeoutMs !== undefined
      && (!Number.isSafeInteger(options.bodyTimeoutMs)
        || options.bodyTimeoutMs < 1))
    || !Number.isSafeInteger(options.upstreamTimeoutMs)
    || options.upstreamTimeoutMs < 1
    || (options.maxBufferedRequests !== undefined
      && (!Number.isSafeInteger(options.maxBufferedRequests)
        || options.maxBufferedRequests < 1))
    || !Number.isSafeInteger(options.maxChunks)
    || options.maxChunks < 1
  ) {
    throw new Error("BODY_GATEWAY_CONFIG_INVALID");
  }

  const bufferedRequests = new Map();
  const server = createServer(async (request, response) => {
    const group = bodyGroupForUrl(request.url);
    const groupPolicy = GROUP_POLICIES[group];
    const maxBytes = LIMITS[group];
    const contract = requestBodyContract(request, maxBytes);
    if (!contract.ok) {
      closeWithStatus(request, response, contract.status);
      return;
    }
    const activeForGroup = bufferedRequests.get(group) ?? 0;
    const groupMaximum = options.maxBufferedRequests
      ?? groupPolicy.maxBufferedRequests;
    if (contract.hasBody && activeForGroup >= groupMaximum) {
      closeWithStatus(request, response, 503);
      return;
    }
    if (contract.hasBody) bufferedRequests.set(group, activeForGroup + 1);
    let released = !contract.hasBody;
    const releaseSlot = () => {
      if (released) return;
      released = true;
      const active = bufferedRequests.get(group) ?? 1;
      if (active <= 1) bufferedRequests.delete(group);
      else bufferedRequests.set(group, active - 1);
    };
    try {
      const body = contract.hasBody
        ? await collectBody(request, maxBytes, {
          ...options,
          bodyTimeoutMs: options.bodyTimeoutMs
            ?? groupPolicy.bodyTimeoutMs,
        })
        : Buffer.alloc(0);
      proxyBufferedRequest(
        request,
        response,
        body,
        contract.chunked,
        options,
        releaseSlot,
      );
    } catch (error) {
      releaseSlot();
      const status = Number.isInteger(error?.status)
        ? error.status
        : 400;
      closeWithStatus(request, response, status);
    }
  });
  server.on("clientError", (_error, socket) => {
    if (socket.writable) {
      socket.end(
        "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
      );
    } else {
      socket.destroy();
    }
  });
  server.on("upgrade", (_request, socket) => socket.destroy());
  server.headersTimeout = 15_000;
  server.requestTimeout = Math.max(
    ...Object.values(GROUP_POLICIES).map((policy) => policy.bodyTimeoutMs),
    options.bodyTimeoutMs ?? 0,
  ) + 5_000;
  server.keepAliveTimeout = 5_000;
  return server;
}

function integerPort(value, fallback) {
  const parsed = Number(value || fallback);
  if (
    !Number.isSafeInteger(parsed)
    || parsed < 1_024
    || parsed > 65_535
  ) {
    throw new Error("BODY_GATEWAY_PORT_INVALID");
  }
  return parsed;
}

async function main() {
  const gatewayPort = integerPort(process.env.PORT, 3_000);
  const nextPort = integerPort(
    process.env.DUINDORP_NEXT_INTERNAL_PORT,
    3_001,
  );
  if (gatewayPort === nextPort) {
    throw new Error("BODY_GATEWAY_PORT_INVALID");
  }
  const nextServerPath = path.resolve(process.cwd(), "server.js");
  const gateway = createBodyLimitGateway({ upstreamPort: nextPort });
  await new Promise((resolve, reject) => {
    const onError = (error) => reject(error);
    gateway.once("error", onError);
    gateway.listen(gatewayPort, "0.0.0.0", () => {
      gateway.off("error", onError);
      resolve();
    });
  });
  const child = spawn(process.execPath, [nextServerPath], {
    stdio: "inherit",
    env: {
      ...process.env,
      HOSTNAME: "127.0.0.1",
      PORT: String(nextPort),
    },
  });
  let stopping = false;
  const stop = (signal = "SIGTERM") => {
    if (stopping) return;
    stopping = true;
    gateway.close();
    gateway.closeAllConnections?.();
    if (child.exitCode === null) child.kill(signal);
  };
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.once(signal, () => stop(signal));
  }
  child.once("error", () => {
    process.exitCode = 1;
    stop();
  });
  child.once("exit", (code) => {
    gateway.close(() => {
      if (!stopping) {
        process.exitCode = code && code > 0
          ? code
          : 1;
      }
    });
  });
  gateway.once("error", () => {
    process.exitCode = 1;
    stop();
  });
  console.log(JSON.stringify({
    event: "body_limit_gateway_started",
    port: gatewayPort,
  }));
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    const code = error instanceof Error
      && /^BODY_GATEWAY_[A-Z0-9_]+$/u.test(error.message)
      ? error.message
      : "BODY_GATEWAY_START_FAILED";
    console.error(JSON.stringify({
      event: "body_limit_gateway_failed",
      code,
    }));
    process.exit(1);
  });
}
