import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const script = readFileSync(
  new URL("./production-rollback-target.sh", import.meta.url),
  "utf8",
);
const promotion = readFileSync(
  new URL("../../.github/workflows/promote-production.yml", import.meta.url),
  "utf8",
);

describe("durable production rollback target", () => {
  it("captures a run-bound candidate and commits revision last", () => {
    expect(script).toContain(".production-rollback-${GITHUB_RUN_ID}.runtime");
    expect(script).toContain("PRODUCTION_ROLLBACK_REVISION");
    expect(script).toContain("PRODUCTION_ROLLBACK_RELEASE_MANIFEST");
    expect(script).toContain(".env.runtime.production-rollback");
    expect(script.indexOf('mv -f -- "${manifest_temp}" "${durable_manifest}"'))
      .toBeLessThan(
        script.indexOf('mv -f -- "${revision_temp}" "${durable_revision}"'),
      );
  });

  it("serializes capture and commit through the staging mutex", () => {
    expect(script).toContain('.deploy.lock');
    expect(script).toContain("flock -n 9");
    expect(promotion).toContain("stage-production-rollback-target");
    expect(promotion).toContain("sync-production-rollback-target");
    expect(promotion).toContain("group: deploy-duindorpteneu-production");
  });

  it("bootstraps pinned Node after the boundary for capture and commit", () => {
    const captureStart = promotion.indexOf("  stage-production-rollback-target:");
    const deployStart = promotion.indexOf("  deploy-production:");
    const syncStart = promotion.indexOf("  sync-production-rollback-target:");
    const cleanupStart = promotion.indexOf(
      "  cleanup-pending-production-rollback-target:",
    );
    const capture = promotion.slice(captureStart, deployStart);
    const sync = promotion.slice(syncStart, cleanupStart);
    const setupNode =
      "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020";

    expect(captureStart).toBeGreaterThan(-1);
    expect(deployStart).toBeGreaterThan(captureStart);
    expect(syncStart).toBeGreaterThan(deployStart);
    expect(cleanupStart).toBeGreaterThan(syncStart);
    for (const [source, command] of [
      [capture, "production-rollback-target.sh capture"],
      [sync, "production-rollback-target.sh commit"],
    ] as const) {
      const boundaryIndex = source.indexOf(
        "assert-runner-boundary.sh staging",
      );
      const nodeIndex = source.indexOf(setupNode);
      expect(boundaryIndex).toBeGreaterThan(-1);
      expect(nodeIndex).toBeGreaterThan(boundaryIndex);
      expect(source.indexOf(command)).toBeGreaterThan(nodeIndex);
      expect(source).toContain("node-version: 22");
    }
  });
});
