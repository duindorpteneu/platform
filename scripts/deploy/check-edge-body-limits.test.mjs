import { createServer } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import { assertEdgeBodyLimits, probeEdgeBodyLimit } from "./check-edge-body-limits.mjs";

const servers = [];

async function serverUrl(handler) {
  const server = createServer(handler);
  servers.push(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("TEST_SERVER_ADDRESS_INVALID");
  return `http://127.0.0.1:${address.port}`;
}

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
});

describe("edge body-limit releaseprobe", () => {
  it("verstuurt zonder Content-Length en bewijst een proxy-413", async () => {
    let headers;
    let received = 0;
    const baseUrl = await serverUrl((request, response) => {
      headers = request.headers;
      request.on("data", (chunk) => { received += chunk.length; });
      request.on("end", () => {
        response.writeHead(413);
        response.end();
      });
    });

    await expect(probeEdgeBodyLimit(baseUrl, {
      name: "test",
      path: "/api/test",
      bytes: 2_049,
    })).resolves.toBe(413);
    expect(headers?.["content-length"]).toBeUndefined();
    expect(headers?.["transfer-encoding"]).toBe("chunked");
    expect(received).toBe(2_049);
  });

  it("faalt wanneer de request de applicatie als 415 bereikt", async () => {
    const baseUrl = await serverUrl((request, response) => {
      request.resume();
      request.on("end", () => {
        response.writeHead(415);
        response.end();
      });
    });

    await expect(assertEdgeBodyLimits(baseUrl, [{
      name: "standard-api",
      path: "/api/test",
      bytes: 1_025,
    }])).rejects.toThrow("EDGE_BODY_LIMIT_FAILED:standard-api:415");
  });
});
