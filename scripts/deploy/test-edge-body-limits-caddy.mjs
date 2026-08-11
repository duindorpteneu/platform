#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  EDGE_BODY_PROBES,
  assertEdgeBodyLimits,
  probeEdgeBodyLimit,
} from "./check-edge-body-limits.mjs";

const caddyImage = "caddy:2.10.2@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83";
const secret = "edge-body-caddy-integration-secret";
const context = { environment: "staging", releaseSha: "c".repeat(40) };
const containers = new Set();

function slowChunkedBody(totalBytes) {
  let remaining = totalBytes;
  return new ReadableStream({
    async pull(controller) {
      if (remaining === 0) {
        controller.close();
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
      const size = Math.min(remaining, 1_024);
      remaining -= size;
      controller.enqueue(new Uint8Array(size));
    },
  });
}

async function freePort() {
  const server = createTcpServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("CADDY_TEST_PORT_INVALID");
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return address.port;
}

async function backendServer() {
  const server = createServer((request, response) => {
    if (!request.headers["x-duindorp-edge-body-probe"]) {
      response.writeHead(403, { "Cache-Control": "no-store" });
      response.end();
      return;
    }
    request.resume();
    request.on("end", () => {
      response.writeHead(204, {
        "Cache-Control": "no-store",
        "X-Duindorp-Edge-Body-Probe-Result": "application-reached",
      });
      response.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("CADDY_TEST_BACKEND_INVALID");
  return { server, port: address.port };
}

function limitsSnippet(source) {
  const start = source.indexOf("(duindorp_request_limits)");
  const end = source.indexOf("\nstaging-duindorp.dgwebservices.nl", start);
  if (start < 0 || end < 0) throw new Error("CADDY_TEST_SNIPPET_INVALID");
  return source.slice(start, end).trim();
}

async function startCaddy(directory, snippet, backendPort) {
  const port = await freePort();
  const name = `duindorp-edge-caddy-${process.pid}-${randomUUID().slice(0, 8)}`;
  const caddyfile = path.join(directory, `${name}.Caddyfile`);
  await writeFile(caddyfile, `{
\tadmin off
\tauto_https off
}

${snippet}

http://127.0.0.1:${port} {
\timport duindorp_request_limits
\treverse_proxy 127.0.0.1:${backendPort}
}
`, { mode: 0o600 });
  // Docker's remapped non-root user must be able to read this secret-free test config.
  await chmod(caddyfile, 0o644);

  execFileSync("docker", [
    "run",
    "--detach",
    "--rm",
    "--name", name,
    "--network", "host",
    "--read-only",
    "--user", "65532:65532",
    "--cap-drop", "ALL",
    "--security-opt", "no-new-privileges:true",
    "--pids-limit", "64",
    "--tmpfs", "/tmp:rw,exec,nosuid,size=64m",
    "--tmpfs", "/data:rw,noexec,nosuid,size=1m",
    "--tmpfs", "/config:rw,noexec,nosuid,size=1m",
    "--mount", `type=bind,src=${caddyfile},dst=/etc/caddy/Caddyfile,readonly`,
    "--entrypoint", "/bin/sh",
    caddyImage,
    "-c", "cp /usr/bin/caddy /tmp/caddy && chmod 755 /tmp/caddy && exec /tmp/caddy \"$@\"",
    "duindorp-edge-caddy",
    "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  containers.add(name);

  const baseUrl = `http://127.0.0.1:${port}`;
  for (let attempt = 1; attempt <= 40; attempt += 1) {
    try {
      const response = await fetch(baseUrl, { signal: AbortSignal.timeout(500) });
      await response.body?.cancel();
      return { baseUrl, name };
    } catch {
      if (attempt === 40) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error("CADDY_TEST_START_TIMEOUT");
}

function stopCaddy(name) {
  if (!containers.has(name)) return;
  const removed = spawnSync("docker", ["rm", "--force", name], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  if (removed.status !== 0) {
    const remaining = spawnSync("docker", ["inspect", name], {
      stdio: ["ignore", "ignore", "ignore"],
    });
    if (remaining.status === 0) throw new Error("CADDY_TEST_CLEANUP_FAILED");
  }
  containers.delete(name);
}

function cleanupContainers() {
  for (const name of [...containers]) {
    try { stopCaddy(name); } catch { /* Best-effort cleanup of exact test containers. */ }
  }
}

for (const [signal, exitCode] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
  process.once(signal, () => {
    cleanupContainers();
    process.exit(exitCode);
  });
}
process.once("exit", cleanupContainers);

async function main() {
  execFileSync("docker", ["version", "--format", "{{.Server.Version}}"], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  const directory = await mkdtemp(path.join(tmpdir(), "duindorp-edge-caddy-"));
  const source = await readFile(
    path.resolve("deploy/caddy/duindorp-tenueportaal.caddy.example"),
    "utf8",
  );
  const backend = await backendServer();
  try {
    const exact = await startCaddy(directory, limitsSnippet(source), backend.port);
    try {
      await assertEdgeBodyLimits(exact.baseUrl, EDGE_BODY_PROBES, fetch, secret, context);

      const earlyResponse = await fetch(new URL("/api/catalog/articles", exact.baseUrl), {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: slowChunkedBody(128_001),
        duplex: "half",
        signal: AbortSignal.timeout(5_000),
      });
      if (earlyResponse.status !== 403) throw new Error("CADDY_TEST_EARLY_RESPONSE_NOT_REPRODUCED");
      await earlyResponse.body?.cancel();
    } finally {
      stopCaddy(exact.name);
    }

    const raisedSnippet = limitsSnippet(source).replace("max_size 128KB", "max_size 256KB");
    if (raisedSnippet === limitsSnippet(source)) throw new Error("CADDY_TEST_RAISED_LIMIT_INVALID");
    const raised = await startCaddy(directory, raisedSnippet, backend.port);
    try {
      let rejected = false;
      try {
        await probeEdgeBodyLimit(raised.baseUrl, EDGE_BODY_PROBES[0], fetch, secret, context);
      } catch (error) {
        rejected = error instanceof Error
          && error.message === "EDGE_BODY_LIMIT_FAILED:standard-api:oversize-status:204";
      }
      if (!rejected) throw new Error("CADDY_TEST_RAISED_LIMIT_NOT_DETECTED");
    } finally {
      stopCaddy(raised.name);
    }
  } finally {
    cleanupContainers();
    await new Promise((resolve) => backend.server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
  process.stdout.write("Caddy 2.10.2 edge-bodycontract bewezen.\n");
}

main().catch((error) => {
  const code = error instanceof Error && /^[A-Z0-9_]+$/.test(error.message)
    ? error.message
    : "CADDY_EDGE_BODY_TEST_FAILED";
  process.stderr.write(`${code}\n`);
  process.exitCode = 1;
});
