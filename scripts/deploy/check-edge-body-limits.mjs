#!/usr/bin/env node

import { pathToFileURL } from "node:url";

const environmentUrls = Object.freeze({
  staging: "https://staging-duindorp.dgwebservices.nl",
  production: "https://duindorp.dgwebservices.nl",
});

export const EDGE_BODY_PROBES = Object.freeze([
  { name: "standard-api", path: "/api/catalog/articles", bytes: 129 * 1_024 },
  { name: "email-bulk", path: "/api/email/bulk", bytes: 385 * 1_024 },
  { name: "sendgrid-webhook", path: "/api/webhooks/sendgrid", bytes: 2 * 1_024 * 1_024 + 1 },
  { name: "sportlink-import", path: "/api/imports/uploads", bytes: 12 * 1_024 * 1_024 + 1 },
]);

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

export async function probeEdgeBodyLimit(baseUrl, probe, fetcher = fetch) {
  const response = await fetcher(new URL(probe.path, baseUrl), {
    method: "POST",
    headers: {
      // De applicatie antwoordt hiermee 415. Alleen een onafhankelijke
      // padgebonden proxylimiet mag al tijdens de chunked upload 413 geven.
      "Content-Type": "application/octet-stream",
      "User-Agent": "duindorp-release-body-limit-probe/1",
    },
    body: chunkedBody(probe.bytes),
    duplex: "half",
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  await response.body?.cancel();
  return response.status;
}

export async function assertEdgeBodyLimits(baseUrl, probes = EDGE_BODY_PROBES, fetcher = fetch) {
  for (const probe of probes) {
    const status = await probeEdgeBodyLimit(baseUrl, probe, fetcher);
    if (status !== 413) {
      throw new Error(`EDGE_BODY_LIMIT_FAILED:${probe.name}:${status}`);
    }
  }
}

async function main() {
  const environment = process.argv[2];
  const expectedUrl = environmentUrls[environment];
  if (!expectedUrl) throw new Error("Gebruik: check-edge-body-limits.mjs staging|production");
  if (process.env.APP_HOST !== new URL(expectedUrl).host) {
    throw new Error("APP_HOST komt niet overeen met de vaste proxyprobe.");
  }
  await assertEdgeBodyLimits(expectedUrl);
  process.stdout.write(`Proxy-bodylimieten bewezen voor ${environment}.\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const message = error instanceof Error && /^EDGE_BODY_LIMIT_FAILED:[a-z-]+:\d+$/.test(error.message)
      ? error.message
      : "Proxy-bodylimietcontrole is mislukt.";
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
