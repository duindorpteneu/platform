#!/usr/bin/env node

import { spawn } from "node:child_process";
import { once } from "node:events";
import { readdir } from "node:fs/promises";
import { request as httpRequest } from "node:http";
import { createServer as createTcpServer } from "node:net";
import path from "node:path";
import {
  EDGE_BODY_PROBES,
  assertEdgeBodyLimits,
} from "./check-edge-body-limits.mjs";

const publicHost = "duindorpsv.dgwebservices.nl";
const secret = "runtime-body-gateway-test-secret";
const context = {
  environment: "staging",
  releaseSha: "e".repeat(40),
  host: publicHost,
};
let runtimeProcess;
let stopping = false;
let runtimeOutput = "";

async function freePort() {
  const server = createTcpServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("RUNTIME_GATEWAY_PORT_INVALID");
  }
  await new Promise((resolve, reject) => server.close(
    (error) => error ? reject(error) : resolve(),
  ));
  return address.port;
}

async function standaloneRoot() {
  const root = path.resolve(".next/standalone");
  const entries = await readdir(root, { recursive: true });
  const candidates = entries.filter((entry) =>
    (entry === "server.js" || entry.endsWith(`${path.sep}server.js`))
    && !entry.split(path.sep).includes("node_modules"));
  if (candidates.length !== 1) {
    throw new Error("RUNTIME_GATEWAY_STANDALONE_INVALID");
  }
  const file = path.resolve(root, candidates[0]);
  if (!file.startsWith(`${root}${path.sep}`)) {
    throw new Error("RUNTIME_GATEWAY_STANDALONE_INVALID");
  }
  return path.dirname(file);
}

function captureOutput(chunk) {
  runtimeOutput = `${runtimeOutput}${String(chunk)}`.slice(-128_000);
}

function terminateGroup(signal) {
  if (!runtimeProcess?.pid || runtimeProcess.exitCode !== null) return;
  try {
    process.kill(-runtimeProcess.pid, signal);
  } catch {
    // The exact disposable process group has already stopped.
  }
}

async function stopRuntime() {
  if (stopping) return;
  stopping = true;
  if (!runtimeProcess || runtimeProcess.exitCode !== null) return;
  terminateGroup("SIGTERM");
  await Promise.race([
    once(runtimeProcess, "exit"),
    new Promise((resolve) => setTimeout(resolve, 3_000)),
  ]);
  if (runtimeProcess.exitCode === null) {
    terminateGroup("SIGKILL");
    await once(runtimeProcess, "exit");
  }
}

for (const [signal, exitCode] of [
  ["SIGINT", 130],
  ["SIGTERM", 143],
  ["SIGHUP", 129],
]) {
  process.once(signal, () => {
    terminateGroup("SIGTERM");
    process.exit(exitCode);
  });
}

async function waitForRuntime(baseUrl) {
  for (let attempt = 1; attempt <= 100; attempt += 1) {
    if (runtimeProcess.exitCode !== null) {
      throw new Error("RUNTIME_GATEWAY_EXITED");
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`, {
        headers: { Host: publicHost },
        signal: AbortSignal.timeout(500),
      });
      await response.body?.cancel();
      if (response.status !== 502) return;
    } catch {
      // Bounded startup retry for the disposable production runtime.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("RUNTIME_GATEWAY_START_TIMEOUT");
}

async function main() {
  const gatewayPort = await freePort();
  const nextPort = await freePort();
  const root = await standaloneRoot();
  const gatewayFile = path.resolve(
    "scripts/runtime/body-limit-gateway.mjs",
  );
  runtimeProcess = spawn(process.execPath, [gatewayFile], {
    cwd: root,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      NODE_ENV: "production",
      NEXT_TELEMETRY_DISABLED: "1",
      HOSTNAME: "0.0.0.0",
      PORT: String(gatewayPort),
      DUINDORP_NEXT_INTERNAL_PORT: String(nextPort),
      CRON_SECRET: secret,
      APP_ENVIRONMENT: context.environment,
      APP_BASE_URL: `https://${publicHost}`,
      RELEASE_SHA: context.releaseSha,
    },
  });
  runtimeProcess.stdout.on("data", captureOutput);
  runtimeProcess.stderr.on("data", captureOutput);
  const baseUrl = `http://127.0.0.1:${gatewayPort}`;
  const publicBaseUrl = `https://${publicHost}`;
  const localProxyFetch = async (input, init = {}) => {
    const publicUrl = new URL(input);
    const headers = new Headers(init.headers);
    headers.set("Host", publicHost);
    headers.set("X-Forwarded-Host", publicHost);
    headers.set("X-Forwarded-Proto", "https");
    headers.set("Transfer-Encoding", "chunked");
    const localUrl = new URL(baseUrl);
    const response = await new Promise((resolve, reject) => {
      const request = httpRequest({
        hostname: localUrl.hostname,
        port: localUrl.port,
        path: `${publicUrl.pathname}${publicUrl.search}`,
        method: init.method,
        headers: Object.fromEntries(headers.entries()),
      }, (incoming) => {
        const chunks = [];
        incoming.on("data", (chunk) => chunks.push(chunk));
        incoming.once("end", () => resolve({
          body: Buffer.concat(chunks),
          headers: incoming.headers,
          status: incoming.statusCode ?? 502,
        }));
      });
      request.once("error", reject);
      request.setTimeout(35_000, () => request.destroy(
        new Error("RUNTIME_GATEWAY_PROXY_TIMEOUT"),
      ));
      const pump = async () => {
        if (!init.body) {
          request.end();
          return;
        }
        const reader = init.body.getReader();
        while (true) {
          const part = await reader.read();
          if (part.done) break;
          if (!request.write(part.value)) await once(request, "drain");
        }
        request.end();
      };
      pump().catch((error) => request.destroy(error));
    });
    const responseHeaders = new Headers();
    for (const [name, value] of Object.entries(response.headers)) {
      if (Array.isArray(value)) {
        for (const item of value) responseHeaders.append(name, item);
      } else if (value !== undefined) responseHeaders.set(name, value);
    }
    return new Response(response.status === 204 ? null : response.body, {
      status: response.status,
      headers: responseHeaders,
    });
  };
  let acceptanceOutputOffset = 0;
  try {
    await waitForRuntime(baseUrl);
    acceptanceOutputOffset = runtimeOutput.length;
    await assertEdgeBodyLimits(
      publicBaseUrl,
      EDGE_BODY_PROBES,
      localProxyFetch,
      secret,
      context,
    );
    if (!runtimeOutput.includes("body_limit_gateway_started")) {
      throw new Error("RUNTIME_GATEWAY_START_MARKER_MISSING");
    }
    if (runtimeOutput.includes(secret)) {
      throw new Error("RUNTIME_GATEWAY_SECRET_LOGGED");
    }
  } catch (error) {
    const upstreamCode = runtimeOutput.slice(acceptanceOutputOffset).match(
      /"event":"body_limit_gateway_upstream_error","code":"([A-Z0-9_]{1,64})"/u,
    )?.[1];
    if (upstreamCode) {
      throw new Error(`RUNTIME_GATEWAY_UPSTREAM_${upstreamCode}`);
    }
    throw error;
  } finally {
    await stopRuntime();
  }
  if (runtimeProcess.exitCode !== 0) {
    throw new Error("RUNTIME_GATEWAY_GRACEFUL_STOP_FAILED");
  }
  process.stdout.write(
    "Immutable runtimegateway en alle vier pre-parser bodycaps bewezen.\n",
  );
}

main().catch(async (error) => {
  await stopRuntime();
  const code = error instanceof Error
    && (
      /^[A-Z0-9_]+$/u.test(error.message)
      || /^EDGE_BODY_LIMIT_FAILED:[a-z-]+:(?:boundary-status|boundary-contract|oversize-status|oversize-contract):\d+$/u
        .test(error.message)
    )
    ? error.message
    : "RUNTIME_BODY_GATEWAY_TEST_FAILED";
  process.stderr.write(`${code}\n`);
  process.exitCode = 1;
});
