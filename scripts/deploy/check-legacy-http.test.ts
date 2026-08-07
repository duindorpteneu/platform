import { spawnSync } from "node:child_process";
import path from "node:path";
import { describe, expect, it } from "vitest";

const script = path.join(import.meta.dirname, "check-legacy-http.mjs");
const legacySha = "a79c8d843d75e90810ccceb228538c6368d2198b";

function run(url: string, environment = "staging", sha = legacySha) {
  return spawnSync(process.execPath, [
    script,
    url,
    environment,
    sha,
  ], { encoding: "utf8" });
}

describe("legacy HTTP target boundary", () => {
  it.each([
    "https://example.invalid",
    "http://localhost:14000",
    "https://staging-duindorp.dgwebservices.nl/other",
    "https://user@staging-duindorp.dgwebservices.nl",
  ])("rejects a non-canonical target before networking", (url) => {
    expect(run(url).status).toBe(2);
  });

  it("rejects every SHA except the single adopted production release", () => {
    expect(run(
      "https://staging-duindorp.dgwebservices.nl",
      "staging",
      "b".repeat(40),
    ).status).toBe(2);
  });

  it("reaches networking only for the exact loopback contract", () => {
    const result = run("http://127.0.0.1:14000");
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("verbinding mislukt");
  });
});
