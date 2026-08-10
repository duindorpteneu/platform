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
});
