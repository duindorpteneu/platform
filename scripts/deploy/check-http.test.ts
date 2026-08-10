import { spawnSync } from "node:child_process";
import path from "node:path";
import { describe, expect, it } from "vitest";

const script = path.join(import.meta.dirname, "check-http.mjs");
const sha = "a".repeat(40);
const digest = `sha256:${"b".repeat(64)}`;

function run(baseUrl: string, environment = "staging") {
  return spawnSync(
    process.execPath,
    [script, baseUrl, environment, sha, digest],
    { encoding: "utf8" },
  );
}

describe("deployment HTTP target boundary", () => {
  it.each([
    "https://example.invalid",
    "http://localhost:14000",
    "http://127.0.0.1:24000",
    "https://staging-duindorp.dgwebservices.nl/other",
    "https://user@staging-duindorp.dgwebservices.nl",
  ])("rejects non-canonical staging target %s before networking", (url) => {
    expect(run(url).status).toBe(2);
  });

  it("accepts only the exact staging loopback contract", () => {
    const result = run("http://127.0.0.1:14000");
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("verbinding mislukt");
  });
});
