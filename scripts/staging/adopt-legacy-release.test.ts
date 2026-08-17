import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  new URL("./adopt-legacy-release.sh", import.meta.url),
  "utf8",
);

describe("one-time staging legacy adoption", () => {
  it("accepts only the captured production SHA and exact staging target", () => {
    expect(source).toContain(
      'legacy_sha="a79c8d843d75e90810ccceb228538c6368d2198b"',
    );
    expect(source).toContain(
      '"https://duindorpsv.dgwebservices.nl"',
    );
    expect(source).toContain("assert_runner_boundary staging");
    expect(source).toContain("legacy-adoption-evidence.mjs verify-capture");
  });

  it("forces every provider off while the legacy image is active", () => {
    expect(source).toContain(
      "node scripts/deploy/normalize-legacy-runtime.mjs",
    );
    expect(source).toContain(
      '"${legacy_sha}" "${legacy_artifact}"',
    );
  });

  it("restores and verifies the candidate even through the EXIT trap", () => {
    expect(source).toContain("trap cleanup EXIT");
    expect(source).toContain("restore_candidate");
    expect(source).toContain("check-legacy-http.mjs");
    expect(source).toContain("check-http.mjs");
    expect(source).toContain("check_scheduler");
    expect(source).toContain("stop_and_check_scheduler");
    expect(source).toContain(
      'compose "${legacy_image}" up -d --no-build app',
    );
    expect(source).not.toContain(
      'compose "${legacy_image}" up -d --no-build --remove-orphans',
    );
    expect(source).toContain("status=70");
    expect(source).not.toMatch(/\bsupabase db push\b/u);
  });

  it("installs the adoption result last as the rollback commit marker", () => {
    expect(source.indexOf('PREVIOUS_RELEASE_MANIFEST"'))
      .toBeLessThan(source.indexOf('LEGACY_ADOPTION_RESULT"'));
    expect(source).toContain("PRODUCTION_ROLLBACK_REVISION");
    expect(source).toContain("PRODUCTION_ROLLBACK_RELEASE_MANIFEST");
    expect(source).toContain(".env.runtime.production-rollback");
    expect(source).toContain(
      "The result is the commit marker and is deliberately installed last.",
    );
  });
});
