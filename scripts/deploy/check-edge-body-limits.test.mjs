import { createHmac } from "node:crypto";
import { createServer } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import {
  assertEdgeBodyLimits,
  createEdgeBodyProbeHeaders,
  edgeBodyProbeSigningPayload,
  probeEdgeBodyLimit,
} from "./check-edge-body-limits.mjs";

const servers = [];
const secret = "edge-body-probe-test-secret-32";
const releaseSha = "a".repeat(40);
const context = { environment: "staging", releaseSha };

async function serverUrl(handler) {
  const server = createServer(handler);
  servers.push(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("TEST_SERVER_ADDRESS_INVALID");
  return `http://127.0.0.1:${address.port}`;
}

function independentlyVerifyProof(request, probe) {
  const timestamp = request.headers["x-duindorp-edge-body-probe-timestamp"];
  const nonce = request.headers["x-duindorp-edge-body-probe-nonce"];
  const bytes = Number(request.headers["x-duindorp-edge-body-probe-bytes"]);
  const expected = createHmac("sha256", secret).update([
    "duindorp-edge-body-probe:v1",
    "POST",
    request.headers.host,
    probe.path,
    "staging",
    releaseSha,
    String(bytes),
    timestamp,
    nonce,
    probe.name,
  ].join("\n")).digest("hex");
  return {
    bytes,
    valid: request.headers["x-duindorp-edge-body-probe"] === "v1"
      && request.headers["x-duindorp-edge-body-probe-signature"] === expected,
  };
}

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
});

describe("edge body-limit releaseprobe", () => {
  it("bewijst exact de grens en grens+1 met chunked HMAC-verzoeken", async () => {
    const probe = { name: "standard-api", path: "/api/test", maxBytes: 2_048 };
    const observations = [];
    const baseUrl = await serverUrl((request, response) => {
      const proof = independentlyVerifyProof(request, probe);
      let received = 0;
      request.on("data", (chunk) => { received += chunk.length; });
      request.on("end", () => {
        observations.push({
          authorization: request.headers.authorization,
          contentLength: request.headers["content-length"],
          transferEncoding: request.headers["transfer-encoding"],
          proof,
          received,
        });
        if (!proof.valid || received !== proof.bytes) {
          response.writeHead(401);
        } else if (proof.bytes === probe.maxBytes) {
          response.writeHead(204, { "X-Duindorp-Edge-Body-Probe-Result": "application-reached" });
        } else {
          response.writeHead(413);
        }
        response.end();
      });
    });

    await expect(probeEdgeBodyLimit(baseUrl, probe, fetch, secret, context)).resolves.toMatchObject({
      boundary: { status: 204, marker: "application-reached" },
      oversize: { status: 413 },
    });
    expect(observations).toHaveLength(2);
    expect(observations.map((entry) => entry.received)).toEqual([2_048, 2_049]);
    for (const observation of observations) {
      expect(observation.authorization).toBeUndefined();
      expect(observation.contentLength).toBeUndefined();
      expect(observation.transferEncoding).toBe("chunked");
      expect(observation.proof.valid).toBe(true);
    }
  });

  it("faalt wanneer een upstream vroeg 403 antwoordt zonder de body te lezen", async () => {
    const probe = { name: "standard-api", path: "/api/test", maxBytes: 1_024 };
    const baseUrl = await serverUrl((_request, response) => {
      response.writeHead(403);
      response.end();
    });

    await expect(assertEdgeBodyLimits(baseUrl, [probe], fetch, secret, context))
      .rejects.toThrow("EDGE_BODY_LIMIT_FAILED:standard-api:boundary-status:403");
  });

  it("faalt wanneer grens+1 de no-op applicatiebranch bereikt", async () => {
    const probe = { name: "standard-api", path: "/api/test", maxBytes: 1_024 };
    const baseUrl = await serverUrl((request, response) => {
      request.resume();
      request.on("end", () => {
        response.writeHead(204, { "X-Duindorp-Edge-Body-Probe-Result": "application-reached" });
        response.end();
      });
    });

    await expect(assertEdgeBodyLimits(baseUrl, [probe], fetch, secret, context))
      .rejects.toThrow("EDGE_BODY_LIMIT_FAILED:standard-api:oversize-status:204");
  });

  it("faalt wanneer een 413 ten onrechte de applicatiemarkering bevat", async () => {
    const probe = { name: "standard-api", path: "/api/test", maxBytes: 1_024 };
    let requestNumber = 0;
    const baseUrl = await serverUrl((request, response) => {
      requestNumber += 1;
      request.resume();
      request.on("end", () => {
        response.writeHead(requestNumber === 1 ? 204 : 413, {
          "X-Duindorp-Edge-Body-Probe-Result": "application-reached",
        });
        response.end();
      });
    });

    await expect(assertEdgeBodyLimits(baseUrl, [probe], fetch, secret, context))
      .rejects.toThrow("EDGE_BODY_LIMIT_FAILED:standard-api:oversize-contract:413");
  });

  it("faalt wanneer de grensresponse niet van de no-op applicatiebranch komt", async () => {
    const probe = { name: "standard-api", path: "/api/test", maxBytes: 1_024 };
    const baseUrl = await serverUrl((request, response) => {
      request.resume();
      request.on("end", () => {
        response.writeHead(204);
        response.end();
      });
    });

    await expect(assertEdgeBodyLimits(baseUrl, [probe], fetch, secret, context))
      .rejects.toThrow("EDGE_BODY_LIMIT_FAILED:standard-api:boundary-contract:204");
  });

  it("maakt een padspecifiek bewijs zonder het geheime bronmateriaal te versturen", () => {
    const probe = { name: "email-bulk", path: "/api/email/bulk", maxBytes: 384_000 };
    const headers = createEdgeBodyProbeHeaders(probe, probe.maxBytes, secret, {
      nowMs: 1_787_680_000_000,
      nonce: "a".repeat(64),
      host: "duindorpsv.dgwebservices.nl",
      ...context,
    });
    const expected = createHmac("sha256", secret)
      .update(edgeBodyProbeSigningPayload({
        ...probe,
        timestamp: headers["X-Duindorp-Edge-Body-Probe-Timestamp"],
        nonce: headers["X-Duindorp-Edge-Body-Probe-Nonce"],
        host: "duindorpsv.dgwebservices.nl",
        ...context,
        bytes: probe.maxBytes,
      }))
      .digest("hex");

    expect(headers["X-Duindorp-Edge-Body-Probe-Signature"]).toBe(expected);
    expect(Object.values(headers)).not.toContain(secret);
    expect(headers).not.toHaveProperty("Authorization");
  });
});
