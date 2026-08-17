import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { POST as catalogPost } from "@/app/api/catalog/articles/route";
import { POST as emailBulkPost } from "@/app/api/email/bulk/route";
import { POST as importUploadPost } from "@/app/api/imports/uploads/route";
import { POST as sendgridPost } from "@/app/api/webhooks/sendgrid/route";
import {
  EDGE_BODY_PROBE_CONTRACT,
  edgeBodyProbeSigningPayload,
  handleEdgeBodyProbe,
  type EdgeBodyProbeName,
} from "@/server/security/edge-body-probe";

const secret = "edge-body-probe-test-secret-32";
const releaseSha = "a".repeat(40);
const repositoryRoot = process.cwd();

function bodyStream(bytes: number) {
  let remaining = bytes;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (remaining === 0) {
        controller.close();
        return;
      }
      const size = Math.min(remaining, 64 * 1_024);
      remaining -= size;
      controller.enqueue(new Uint8Array(size));
    },
  });
}

function probeRequest(
  name: EdgeBodyProbeName,
  options: {
    actualBytes?: number;
    declaredBytes?: number;
    timestamp?: number;
    signature?: string;
    requestUrl?: string;
  } = {},
) {
  const contract = EDGE_BODY_PROBE_CONTRACT[name];
  const declaredBytes = options.declaredBytes ?? contract.maxBytes;
  const timestamp = String(options.timestamp ?? Math.floor(Date.now() / 1_000));
  const nonce = "a".repeat(64);
  const signature = options.signature ?? createHmac("sha256", secret)
    .update(edgeBodyProbeSigningPayload({
      version: "v1",
      timestamp,
      nonce,
      name,
      host: "duindorpsv.dgwebservices.nl",
      path: contract.path,
      environment: "staging",
      releaseSha,
      bytes: declaredBytes,
    }))
    .digest("hex");
  return new Request(options.requestUrl ?? `https://0.0.0.0:3000${contract.path}`, {
    method: "POST",
    headers: {
      "Host": "duindorpsv.dgwebservices.nl",
      "X-Forwarded-Host": "duindorpsv.dgwebservices.nl",
      "X-Forwarded-Proto": "https",
      "Content-Type": "application/octet-stream",
      "X-Duindorp-Edge-Body-Probe": "v1",
      "X-Duindorp-Edge-Body-Probe-Timestamp": timestamp,
      "X-Duindorp-Edge-Body-Probe-Nonce": nonce,
      "X-Duindorp-Edge-Body-Probe-Bytes": String(declaredBytes),
      "X-Duindorp-Edge-Body-Probe-Environment": "staging",
      "X-Duindorp-Edge-Body-Probe-Release": releaseSha,
      "X-Duindorp-Edge-Body-Probe-Signature": signature,
    },
    body: bodyStream(options.actualBytes ?? declaredBytes),
    duplex: "half",
  } as RequestInit & { duplex: "half" });
}

afterEach(() => {
  delete process.env.CRON_SECRET;
  delete process.env.APP_ENVIRONMENT;
  delete process.env.APP_BASE_URL;
  delete process.env.RELEASE_SHA;
});

function configureRuntime() {
  process.env.CRON_SECRET = secret;
  process.env.APP_ENVIRONMENT = "staging";
  process.env.APP_BASE_URL = "https://duindorpsv.dgwebservices.nl";
  process.env.RELEASE_SHA = releaseSha;
}

describe("edge body-probe applicatiecontract", () => {
  it("accepteert de interne Next-URL met geverifieerde publieke proxyheaders", async () => {
    configureRuntime();
    const request = probeRequest("standard-api");

    const response = await handleEdgeBodyProbe(request, "standard-api");

    expect(response?.status).toBe(204);
    expect(response?.headers.get("x-duindorp-edge-body-probe-result")).toBe("application-reached");
    expect(response?.headers.get("cache-control")).toBe("no-store");
    expect(request.bodyUsed).toBe(true);
    expect(request.url).toBe("https://0.0.0.0:3000/api/catalog/articles");
  });

  it("retourneert ook bij grens+1 nooit zelf 413", async () => {
    configureRuntime();
    const contract = EDGE_BODY_PROBE_CONTRACT["standard-api"];
    const request = probeRequest("standard-api", {
      actualBytes: contract.maxBytes + 1,
      declaredBytes: contract.maxBytes + 1,
    });

    const response = await handleEdgeBodyProbe(request, "standard-api");

    expect(response?.status).toBe(204);
    expect(response?.status).not.toBe(413);
  });

  it("weigert een ongeldig of verlopen bewijs vóór de body-read", async () => {
    configureRuntime();
    const invalid = probeRequest("standard-api", { signature: "0".repeat(64) });
    const expired = probeRequest("standard-api", {
      timestamp: Math.floor(Date.now() / 1_000) - 61,
    });

    expect((await handleEdgeBodyProbe(invalid, "standard-api"))?.status).toBe(401);
    expect((await handleEdgeBodyProbe(expired, "standard-api"))?.status).toBe(401);
    expect(invalid.bodyUsed).toBe(false);
    expect(expired.bodyUsed).toBe(false);
  });

  it("geeft een applicatiefout anders dan 413 bij een onvolledige body", async () => {
    configureRuntime();
    const contract = EDGE_BODY_PROBE_CONTRACT["standard-api"];
    const request = probeRequest("standard-api", {
      actualBytes: contract.maxBytes - 1,
      declaredBytes: contract.maxBytes,
    });

    const response = await handleEdgeBodyProbe(request, "standard-api");

    expect(response?.status).toBe(422);
    expect(response?.status).not.toBe(413);
  });

  it("laat normale requests volledig aan de bestaande routebeveiliging over", async () => {
    const request = new Request("https://duindorpsv.dgwebservices.nl/api/catalog/articles", {
      method: "POST",
      body: "{}",
    });

    expect(await handleEdgeBodyProbe(request, "standard-api")).toBeNull();
    expect(request.bodyUsed).toBe(false);
  });

  it("weigert ieder partieel of gemanipuleerd bewijs vóór de body-read", async () => {
    configureRuntime();
    const cases = [
      (request: Request) => request.headers.delete("x-duindorp-edge-body-probe"),
      (request: Request) => {
        for (const header of [...request.headers.keys()]) request.headers.delete(header);
        request.headers.set("x-duindorp-edge-body-probe-result", "application-reached");
      },
      (request: Request) => request.headers.set("x-duindorp-edge-body-probe-environment", "production"),
      (request: Request) => request.headers.set("x-duindorp-edge-body-probe-release", "b".repeat(40)),
      (request: Request) => request.headers.set("x-duindorp-edge-body-probe-nonce", "b".repeat(64)),
      (request: Request) => request.headers.set("x-duindorp-edge-body-probe-bytes", "128002"),
      (request: Request) => request.headers.set("content-type", "application/json"),
      (request: Request) => request.headers.set("content-encoding", "gzip"),
      (request: Request) => request.headers.set("content-length", "128000"),
      (request: Request) => request.headers.delete("host"),
      (request: Request) => request.headers.set("host", "duindorp.dgwebservices.nl"),
      (request: Request) => request.headers.delete("x-forwarded-host"),
      (request: Request) => request.headers.set("x-forwarded-host", "duindorpsv.dgwebservices.nl, attacker.example"),
      (request: Request) => request.headers.set("x-forwarded-host", "attacker.example"),
      (request: Request) => request.headers.delete("x-forwarded-proto"),
      (request: Request) => request.headers.set("x-forwarded-proto", "http"),
    ];

    for (const tamper of cases) {
      const request = probeRequest("standard-api");
      tamper(request);
      expect((await handleEdgeBodyProbe(request, "standard-api"))?.status).toBe(401);
      expect(request.bodyUsed).toBe(false);
    }
  });

  it("weigert een verkeerd pad en toekomstige timestamp vóór de body-read", async () => {
    configureRuntime();
    const wrongPath = probeRequest("standard-api", {
      requestUrl: "https://0.0.0.0:3000/api/email/bulk",
    });
    const future = probeRequest("standard-api", {
      timestamp: Math.floor(Date.now() / 1_000) + 31,
    });

    for (const request of [wrongPath, future]) {
      expect((await handleEdgeBodyProbe(request, "standard-api"))?.status).toBe(401);
      expect(request.bodyUsed).toBe(false);
    }
  });

  it("geeft bij meer bytes dan ondertekend een applicatiefout anders dan 413", async () => {
    configureRuntime();
    const contract = EDGE_BODY_PROBE_CONTRACT["standard-api"];
    const request = probeRequest("standard-api", {
      actualBytes: contract.maxBytes + 1,
      declaredBytes: contract.maxBytes,
    });

    const response = await handleEdgeBodyProbe(request, "standard-api");
    expect(response?.status).toBe(422);
    expect(response?.status).not.toBe(413);
  });
});

describe("edge body-probe routevolgorde", () => {
  const routes = [
    ["standard-api", "src/app/api/catalog/articles/route.ts", "guardBrowserMutation"],
    ["email-bulk", "src/app/api/email/bulk/route.ts", "guardBrowserMutation"],
    ["sendgrid-webhook", "src/app/api/webhooks/sendgrid/route.ts", "SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY"],
    ["sportlink-import", "src/app/api/imports/uploads/route.ts", "guardBrowserMutation"],
  ] as const;

  it.each(routes)("activeert %s alleen vóór vroeg antwoordende routeguards", (name, route, normalGuard) => {
    const source = readFileSync(path.join(repositoryRoot, route), "utf8");
    const probeCall = `handleEdgeBodyProbe(request, \"${name}\")`;
    expect(source).toContain(probeCall);
    expect(source.indexOf(probeCall)).toBeLessThan(source.indexOf(normalGuard, source.indexOf("export async function POST")));
  });

  it.each([
    ["standard-api", catalogPost],
    ["email-bulk", emailBulkPost],
    ["sendgrid-webhook", sendgridPost],
    ["sportlink-import", importUploadPost],
  ] as const)("bereikt voor %s geen businesslogica na een geldige grensprobe", async (name, handler) => {
    configureRuntime();
    const response = await handler(probeRequest(name));
    expect(response.status).toBe(204);
    expect(response.headers.get("x-duindorp-edge-body-probe-result")).toBe("application-reached");
  });
});
