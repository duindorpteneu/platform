#!/usr/bin/env node

import { createHmac, randomBytes } from "node:crypto";
import { pathToFileURL } from "node:url";
import rawContract from "../../deploy/edge-body-probe-contract.json" with { type: "json" };

const environmentUrls = Object.freeze({
  staging: "https://duindorpsv.dgwebservices.nl",
  production: "https://duindorp.dgwebservices.nl",
});

function loadContract() {
  if (rawContract.version !== "v1"
    || !Number.isSafeInteger(rawContract.freshnessSeconds)
    || rawContract.freshnessSeconds < 10
    || rawContract.freshnessSeconds > 300
    || !Array.isArray(rawContract.probes)
    || rawContract.probes.length !== 4) {
    throw new Error("EDGE_BODY_PROBE_CONTRACT_INVALID");
  }
  const names = new Set();
  return Object.freeze(rawContract.probes.map((probe) => {
    if (!probe
      || !/^[a-z-]+$/.test(probe.name)
      || names.has(probe.name)
      || !probe.path.startsWith("/api/")
      || !Number.isSafeInteger(probe.maxBytes)
      || probe.maxBytes < 1) {
      throw new Error("EDGE_BODY_PROBE_CONTRACT_INVALID");
    }
    names.add(probe.name);
    return Object.freeze({ ...probe });
  }));
}

export const EDGE_BODY_PROBES = loadContract();

function chunkedBody(totalBytes, chunkBytes = 64 * 1_024) {
  let remaining = totalBytes;
  return new ReadableStream({
    pull(controller) {
      if (remaining === 0) {
        controller.close();
        return;
      }
      const size = Math.min(remaining, chunkBytes);
      remaining -= size;
      controller.enqueue(new Uint8Array(size));
    },
  });
}

export function edgeBodyProbeSigningPayload(input) {
  return [
    `duindorp-edge-body-probe:${rawContract.version}`,
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

export function createEdgeBodyProbeHeaders(probe, bytes, secret, options = {}) {
  if (typeof secret !== "string" || secret.length < 16) {
    throw new Error("EDGE_BODY_PROBE_SECRET_INVALID");
  }
  const timestamp = String(Math.floor((options.nowMs ?? Date.now()) / 1_000));
  const nonce = options.nonce ?? randomBytes(32).toString("hex");
  if (!/^\d{10}$/.test(timestamp)
    || !/^[a-f0-9]{64}$/.test(nonce)
    || !/^[a-z0-9.-]+(?::\d+)?$/.test(options.host ?? "")
    || !["staging", "production"].includes(options.environment)
    || !/^[a-f0-9]{40}$/.test(options.releaseSha ?? "")) {
    throw new Error("EDGE_BODY_PROBE_INPUT_INVALID");
  }
  const signature = createHmac("sha256", secret)
    .update(edgeBodyProbeSigningPayload({
      ...probe,
      timestamp,
      nonce,
      bytes,
      host: options.host,
      environment: options.environment,
      releaseSha: options.releaseSha,
    }))
    .digest("hex");
  return {
    "Content-Type": "application/octet-stream",
    "User-Agent": "duindorp-release-body-limit-probe/2",
    "X-Duindorp-Edge-Body-Probe": rawContract.version,
    "X-Duindorp-Edge-Body-Probe-Timestamp": timestamp,
    "X-Duindorp-Edge-Body-Probe-Nonce": nonce,
    "X-Duindorp-Edge-Body-Probe-Bytes": String(bytes),
    "X-Duindorp-Edge-Body-Probe-Environment": options.environment,
    "X-Duindorp-Edge-Body-Probe-Release": options.releaseSha,
    "X-Duindorp-Edge-Body-Probe-Signature": signature,
  };
}

export async function probeEdgeBodyRequest(
  baseUrl,
  probe,
  bytes,
  fetcher = fetch,
  secret = process.env.CRON_SECRET,
  context = {},
) {
  const host = new URL(baseUrl).host.toLowerCase();
  const response = await fetcher(new URL(probe.path, baseUrl), {
    method: "POST",
    headers: createEdgeBodyProbeHeaders(probe, bytes, secret, { ...context, host }),
    body: chunkedBody(bytes),
    duplex: "half",
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  const result = Object.freeze({
    status: response.status,
    marker: response.headers.get("x-duindorp-edge-body-probe-result"),
  });
  await response.body?.cancel();
  return result;
}

export async function probeEdgeBodyLimit(
  baseUrl,
  probe,
  fetcher = fetch,
  secret = process.env.CRON_SECRET,
  context = {},
) {
  const boundary = await probeEdgeBodyRequest(
    baseUrl,
    probe,
    probe.maxBytes,
    fetcher,
    secret,
    context,
  );
  if (boundary.status !== 204) {
    throw new Error(`EDGE_BODY_LIMIT_FAILED:${probe.name}:boundary-status:${boundary.status}`);
  }
  if (boundary.marker !== "application-reached") {
    throw new Error(`EDGE_BODY_LIMIT_FAILED:${probe.name}:boundary-contract:${boundary.status}`);
  }

  const oversize = await probeEdgeBodyRequest(
    baseUrl,
    probe,
    probe.maxBytes + 1,
    fetcher,
    secret,
    context,
  );
  if (oversize.status !== 413) {
    throw new Error(`EDGE_BODY_LIMIT_FAILED:${probe.name}:oversize-status:${oversize.status}`);
  }
  if (oversize.marker !== null) {
    throw new Error(`EDGE_BODY_LIMIT_FAILED:${probe.name}:oversize-contract:${oversize.status}`);
  }
  return Object.freeze({ boundary, oversize });
}

export async function assertEdgeBodyLimits(
  baseUrl,
  probes = EDGE_BODY_PROBES,
  fetcher = fetch,
  secret = process.env.CRON_SECRET,
  context = {},
) {
  for (const probe of probes) {
    await probeEdgeBodyLimit(baseUrl, probe, fetcher, secret, context);
  }
}

async function main() {
  const environment = process.argv[2];
  const expectedUrl = environmentUrls[environment];
  if (!expectedUrl) throw new Error("Gebruik: check-edge-body-limits.mjs staging|production");
  if (process.env.APP_HOST !== new URL(expectedUrl).host) {
    throw new Error("APP_HOST komt niet overeen met de vaste proxyprobe.");
  }
  if (!process.env.CRON_SECRET || process.env.CRON_SECRET.length < 16) {
    throw new Error("Edge-body-probe is niet geconfigureerd.");
  }
  await assertEdgeBodyLimits(expectedUrl, EDGE_BODY_PROBES, fetch, process.env.CRON_SECRET, {
    environment,
    releaseSha: process.env.RELEASE_SHA,
  });
  process.stdout.write(`Proxy-bodylimieten bewezen voor ${environment}.\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const message = error instanceof Error
      && /^EDGE_BODY_LIMIT_FAILED:[a-z-]+:(?:boundary-status|boundary-contract|oversize-status|oversize-contract):\d+$/.test(error.message)
      ? error.message
      : "Proxy-bodylimietcontrole is mislukt.";
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
