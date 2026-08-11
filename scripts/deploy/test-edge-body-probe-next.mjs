#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createServer as createTcpServer } from "node:net";
import { once } from "node:events";
import { request as httpRequest } from "node:http";
import { readdir } from "node:fs/promises";
import path from "node:path";
import {
  EDGE_BODY_PROBES,
  createEdgeBodyProbeHeaders,
} from "./check-edge-body-limits.mjs";

const publicHost = "staging-duindorp.dgwebservices.nl";
const secret = "edge-body-next-runtime-secret";
const context = {
  environment: "staging",
  releaseSha: "d".repeat(40),
  host: publicHost,
};
let nextProcess;
let shuttingDown = false;
let runtimeOutput = "";

async function freePort() {
  const server = createTcpServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("NEXT_PROBE_PORT_INVALID");
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return address.port;
}

async function standaloneServer() {
  const root = path.resolve(".next/standalone");
  const entries = await readdir(root, { recursive: true });
  const candidates = entries.filter((entry) =>
    (entry === "server.js" || entry.endsWith(`${path.sep}server.js`))
    && !entry.split(path.sep).includes("node_modules"));
  if (candidates.length !== 1) throw new Error("NEXT_PROBE_STANDALONE_INVALID");
  const file = path.resolve(root, candidates[0]);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error("NEXT_PROBE_STANDALONE_INVALID");
  return file;
}

function captureOutput(chunk) {
  runtimeOutput = `${runtimeOutput}${String(chunk)}`.slice(-128_000);
}

function terminateProcessGroup(signal) {
  if (!nextProcess?.pid || nextProcess.exitCode !== null) return;
  try { process.kill(-nextProcess.pid, signal); } catch { /* Exact test group already stopped. */ }
}

async function stopNext() {
  if (shuttingDown) return;
  shuttingDown = true;
  if (!nextProcess || nextProcess.exitCode !== null) return;
  terminateProcessGroup("SIGTERM");
  await Promise.race([
    once(nextProcess, "exit"),
    new Promise((resolve) => setTimeout(resolve, 3_000)),
  ]);
  if (nextProcess.exitCode === null) {
    terminateProcessGroup("SIGKILL");
    await once(nextProcess, "exit");
  }
}

for (const [signal, exitCode] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
  process.once(signal, () => {
    terminateProcessGroup("SIGTERM");
    process.exit(exitCode);
  });
}

async function waitForNext(baseUrl) {
  for (let attempt = 1; attempt <= 80; attempt += 1) {
    if (nextProcess.exitCode !== null) throw new Error("NEXT_PROBE_RUNTIME_EXITED");
    try {
      const response = await fetch(`${baseUrl}/api/health`, {
        headers: { Host: publicHost },
        signal: AbortSignal.timeout(500),
      });
      await response.body?.cancel();
      return;
    } catch {
      if (attempt === 80) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error("NEXT_PROBE_RUNTIME_TIMEOUT");
}

async function sendProbe(baseUrl, probe, bytes) {
  const url = new URL(baseUrl);
  const result = await new Promise((resolve, reject) => {
    const request = httpRequest({
      hostname: url.hostname,
      port: url.port,
      path: probe.path,
      method: "POST",
      headers: {
        ...createEdgeBodyProbeHeaders(probe, bytes, secret, context),
        Host: publicHost,
        "X-Forwarded-Host": publicHost,
        "X-Forwarded-Proto": "https",
        "Transfer-Encoding": "chunked",
      },
    }, (response) => {
      response.resume();
      response.once("end", () => resolve({
        status: response.statusCode,
        marker: response.headers["x-duindorp-edge-body-probe-result"] ?? null,
      }));
    });
    request.once("error", reject);
    request.setTimeout(30_000, () => request.destroy(new Error("NEXT_PROBE_REQUEST_TIMEOUT")));
    let remaining = bytes;
    const write = () => {
      while (remaining > 0) {
        const size = Math.min(remaining, 64 * 1_024);
        remaining -= size;
        if (!request.write(Buffer.alloc(size))) {
          request.once("drain", write);
          return;
        }
      }
      request.end();
    };
    write();
  });
  if (result.status !== 204 || result.marker !== "application-reached") {
    throw new Error(`NEXT_PROBE_CONTRACT_FAILED_${probe.name.replaceAll("-", "_").toUpperCase()}_${result.status}`);
  }
}

async function main() {
  const port = await freePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverFile = await standaloneServer();
  nextProcess = spawn(
    process.execPath,
    [serverFile],
    {
      cwd: path.dirname(serverFile),
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        NODE_ENV: "production",
        NEXT_TELEMETRY_DISABLED: "1",
        HOSTNAME: "0.0.0.0",
        PORT: String(port),
        CRON_SECRET: secret,
        APP_ENVIRONMENT: context.environment,
        APP_BASE_URL: `https://${publicHost}`,
        RELEASE_SHA: context.releaseSha,
      },
    },
  );
  nextProcess.stdout.on("data", captureOutput);
  nextProcess.stderr.on("data", captureOutput);

  try {
    await waitForNext(baseUrl);
    const standard = EDGE_BODY_PROBES.find((probe) => probe.name === "standard-api");
    const sportlink = EDGE_BODY_PROBES.find((probe) => probe.name === "sportlink-import");
    if (!standard || !sportlink) throw new Error("NEXT_PROBE_CONTRACT_INVALID");
    await sendProbe(baseUrl, standard, standard.maxBytes);
    await sendProbe(baseUrl, sportlink, sportlink.maxBytes);
    await sendProbe(baseUrl, sportlink, sportlink.maxBytes + 1);
    if (runtimeOutput.includes("Request body exceeded")) {
      throw new Error("NEXT_PROBE_MIDDLEWARE_TRUNCATED_BODY");
    }
  } finally {
    await stopNext();
  }
  process.stdout.write("Next proxy-URL en 12MB-middlewarecontract bewezen.\n");
}

main().catch(async (error) => {
  await stopNext();
  const code = error instanceof Error && /^[A-Z0-9_]+$/.test(error.message)
    ? error.message
    : "NEXT_EDGE_BODY_TEST_FAILED";
  process.stderr.write(`${code}\n`);
  process.exitCode = 1;
});
