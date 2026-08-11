import { once } from "node:events";
import { createServer, request as httpRequest } from "node:http";
import { createConnection, type AddressInfo } from "node:net";
import {
  afterEach,
  describe,
  expect,
  it,
} from "vitest";
// @ts-expect-error The shell-less runtime entrypoint is intentionally plain Node.js ESM.
import { bodyLimitForUrl, createBodyLimitGateway } from "./body-limit-gateway.mjs";

const servers: ReturnType<typeof createServer>[] = [];

async function listen(server: ReturnType<typeof createServer>) {
  servers.push(server);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return (server.address() as AddressInfo).port;
}

afterEach(async () => {
  await Promise.all(servers.splice(0).map(async (server) => {
    server.closeAllConnections?.();
    if (server.listening) {
      server.close();
      await once(server, "close");
    }
  }));
});

function sendChunked(port: number, path: string, bytes: number) {
  return new Promise<{
    status: number | undefined;
    marker: string | string[] | undefined;
  }>((resolve, reject) => {
    const request = httpRequest({
      hostname: "127.0.0.1",
      port,
      path,
      method: "POST",
      headers: { "Transfer-Encoding": "chunked" },
    }, (response) => {
      response.resume();
      response.once("end", () => resolve({
        status: response.statusCode,
        marker: response.headers["x-upstream-marker"],
      }));
    });
    request.once("error", reject);
    let remaining = bytes;
    while (remaining > 0) {
      const size = Math.min(remaining, 64 * 1_024);
      remaining -= size;
      request.write(Buffer.alloc(size));
    }
    request.end();
  });
}

function sendRaw(port: number, rawRequest: string) {
  return new Promise<number>((resolve, reject) => {
    const socket = createConnection({ host: "127.0.0.1", port });
    let response = "";
    socket.setEncoding("utf8");
    socket.setTimeout(2_000, () => socket.destroy(
      new Error("RAW_GATEWAY_TEST_TIMEOUT"),
    ));
    socket.once("connect", () => socket.end(rawRequest));
    socket.on("data", (chunk) => { response += chunk; });
    socket.once("error", reject);
    socket.once("end", () => {
      const status = Number(response.match(/^HTTP\/1\.1 (\d{3})/u)?.[1]);
      if (!Number.isInteger(status)) reject(new Error("RAW_GATEWAY_RESPONSE_INVALID"));
      else resolve(status);
    });
  });
}

describe("immutable runtime body-limit gateway", () => {
  it("uses the shared non-overlapping route caps", () => {
    expect(bodyLimitForUrl("/api/catalog/articles")).toBe(128_000);
    expect(bodyLimitForUrl("/api/email/bulk")).toBe(384_000);
    expect(bodyLimitForUrl("/api/email/v2/campaigns")).toBe(384_000);
    expect(bodyLimitForUrl("/api/webhooks/sendgrid")).toBe(2_000_000);
    for (const path of [
      "/api/imports/uploads",
      "/api/imports/preview",
      "/api/imports/commit",
    ]) {
      expect(bodyLimitForUrl(path)).toBe(12_000_000);
    }
    expect(bodyLimitForUrl("/mijn-tenue")).toBe(128_000);
  });

  it("buffers before Next, preserves chunked semantics and rejects max plus one", async () => {
    let upstreamCalls = 0;
    let upstreamContentLength: string | undefined;
    let upstreamTransferEncoding: string | undefined;
    const upstream = createServer((request, response) => {
      upstreamCalls += 1;
      upstreamContentLength = request.headers["content-length"];
      upstreamTransferEncoding = request.headers["transfer-encoding"];
      request.resume();
      request.once("end", () => {
        response.writeHead(204, { "X-Upstream-Marker": "reached" });
        response.end();
      });
    });
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({ upstreamPort });
    const gatewayPort = await listen(gateway);

    await expect(sendChunked(
      gatewayPort,
      "/api/catalog/articles",
      128_000,
    )).resolves.toEqual({ status: 204, marker: "reached" });
    expect(upstreamContentLength).toBeUndefined();
    expect(upstreamTransferEncoding).toBe("chunked");

    await expect(sendChunked(
      gatewayPort,
      "/api/catalog/articles",
      128_001,
    )).resolves.toEqual({ status: 413, marker: undefined });
    expect(upstreamCalls).toBe(1);
  });

  it("rejects every route-group oversize before upstream side effects", async () => {
    let upstreamCalls = 0;
    const upstream = createServer((_request, response) => {
      upstreamCalls += 1;
      response.writeHead(403, { "X-Upstream-Marker": "early" });
      response.end();
    });
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({ upstreamPort });
    const gatewayPort = await listen(gateway);
    for (const [path, bytes] of [
      ["/api/catalog/articles", 128_001],
      ["/api/email/bulk", 384_001],
      ["/api/webhooks/sendgrid", 2_000_001],
      ["/api/imports/uploads", 12_000_001],
    ] as const) {
      await expect(sendChunked(gatewayPort, path, bytes))
        .resolves.toEqual({ status: 413, marker: undefined });
    }
    expect(upstreamCalls).toBe(0);
  });

  it("fails closed on oversized Content-Length without reading or forwarding", async () => {
    let upstreamCalls = 0;
    const upstream = createServer(() => { upstreamCalls += 1; });
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({ upstreamPort });
    const gatewayPort = await listen(gateway);
    const result = await new Promise<number | undefined>((resolve, reject) => {
      const request = httpRequest({
        hostname: "127.0.0.1",
        port: gatewayPort,
        path: "/api/catalog/articles",
        method: "POST",
        headers: { "Content-Length": "128001" },
      }, (response) => {
        response.resume();
        response.once("end", () => resolve(response.statusCode));
      });
      request.once("error", reject);
      request.end();
    });
    expect(result).toBe(413);
    expect(upstreamCalls).toBe(0);
  });

  it("rejects ambiguous or unsupported HTTP body framing", async () => {
    let upstreamCalls = 0;
    const upstream = createServer(() => { upstreamCalls += 1; });
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({ upstreamPort });
    const gatewayPort = await listen(gateway);
    for (const request of [
      "POST /api/catalog/articles HTTP/1.1\r\nHost: test\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n",
      "POST /api/catalog/articles HTTP/1.1\r\nHost: test\r\nContent-Length: 1\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
      "POST /api/catalog/articles HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: gzip, chunked\r\nConnection: close\r\n\r\n0\r\n\r\n",
    ]) {
      await expect(sendRaw(gatewayPort, request)).resolves.toBe(400);
    }
    expect(upstreamCalls).toBe(0);
  });

  it("removes hop-by-hop and Connection-nominated headers", async () => {
    let upstreamHeaders: Record<string, string | string[] | undefined> = {};
    const upstream = createServer((request, response) => {
      upstreamHeaders = request.headers;
      request.resume();
      request.once("end", () => response.end());
    });
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({ upstreamPort });
    const gatewayPort = await listen(gateway);
    const result = await new Promise<number | undefined>((resolve, reject) => {
      const request = httpRequest({
        hostname: "127.0.0.1",
        port: gatewayPort,
        path: "/api/catalog/articles",
        method: "POST",
        headers: {
          Connection: "keep-alive, x-remove-me",
          "Content-Length": "1",
          "X-Remove-Me": "unsafe",
        },
      }, (response) => {
        response.resume();
        response.once("end", () => resolve(response.statusCode));
      });
      request.once("error", reject);
      request.end("x");
    });
    expect(result).toBe(200);
    expect(upstreamHeaders["x-remove-me"]).toBeUndefined();
    expect(upstreamHeaders.connection).not.toContain("x-remove-me");
  });

  it("bounds buffered concurrency before accepting another body", async () => {
    const upstream = createServer((_request, response) => response.end());
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({
      upstreamPort,
      maxBufferedRequests: 1,
      bodyTimeoutMs: 5_000,
    });
    const gatewayPort = await listen(gateway);
    const first = httpRequest({
      hostname: "127.0.0.1",
      port: gatewayPort,
      path: "/api/catalog/articles",
      method: "POST",
      headers: { "Transfer-Encoding": "chunked" },
    });
    first.on("error", () => undefined);
    first.write(Buffer.alloc(1));
    await new Promise((resolve) => setTimeout(resolve, 10));
    await expect(sendChunked(
      gatewayPort,
      "/api/catalog/articles",
      1,
    )).resolves.toEqual({ status: 503, marker: undefined });
    first.destroy();
  });

  it("isolates slow-body admission between route groups", async () => {
    let upstreamCalls = 0;
    const upstream = createServer((request, response) => {
      upstreamCalls += 1;
      request.resume();
      request.once("end", () => response.end());
    });
    const upstreamPort = await listen(upstream);
    const gateway = createBodyLimitGateway({
      upstreamPort,
      maxBufferedRequests: 1,
      bodyTimeoutMs: 5_000,
    });
    const gatewayPort = await listen(gateway);
    const slowImport = httpRequest({
      hostname: "127.0.0.1",
      port: gatewayPort,
      path: "/api/imports/uploads",
      method: "POST",
      headers: { "Transfer-Encoding": "chunked" },
    });
    slowImport.on("error", () => undefined);
    slowImport.write(Buffer.alloc(1));
    await new Promise((resolve) => setTimeout(resolve, 10));
    await expect(sendChunked(
      gatewayPort,
      "/api/catalog/articles",
      1,
    )).resolves.toEqual({ status: 200, marker: undefined });
    expect(upstreamCalls).toBe(1);
    slowImport.destroy();
  });
});
