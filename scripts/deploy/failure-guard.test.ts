import { spawnSync } from "node:child_process";
import path from "node:path";
import { describe, expect, it } from "vitest";

const guard = path.join(import.meta.dirname, "failure-guard.sh");

function run(body: string) {
  return spawnSync("bash", ["-c", `
    set -Eeuo pipefail
    source "$1"
    ${body}
  `, "failure-guard-test", guard], {
    encoding: "utf8",
  });
}

describe("deployment failure guard", () => {
  it("exits normally before application activation", () => {
    const result = run(`
      activated=false
      rollback() { printf 'unexpected-rollback\\n'; exit 42; }
      deployment_die 'preflight failed'
    `);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("preflight failed");
    expect(result.stdout).not.toContain("unexpected-rollback");
  });

  it("always transfers an activated failure to rollback", () => {
    const result = run(`
      activated=true
      rollback() { printf 'rollback-invoked:%s\\n' "$1"; exit 42; }
      deployment_die 'post-activation failed'
    `);
    expect(result.status).toBe(42);
    expect(result.stderr).toContain("post-activation failed");
    expect(result.stdout).toContain("rollback-invoked:1");
  });
});
