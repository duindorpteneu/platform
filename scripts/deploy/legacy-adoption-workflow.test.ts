import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const workflow = readFileSync(
  new URL(
    "../../.github/workflows/adopt-legacy-production.yml",
    import.meta.url,
  ),
  "utf8",
);

describe("protected one-time legacy adoption workflow", () => {
  it("shares the deployment lock and requires production approval", () => {
    expect(workflow).toContain("group: deploy-duindorpteneu-staging");
    expect(workflow).toContain("environment:\n      name: production");
    expect(workflow).toContain(
      "ADOPT-LEGACY-PRODUCTION-a79c8d843d75e90810ccceb228538c6368d2198b",
    );
    expect(workflow).toContain("verify-legacy-history.mjs");
  });

  it("uses distinct runner boundaries and no environment secrets", () => {
    expect(workflow).toContain(
      "bash scripts/deploy/assert-runner-boundary.sh production",
    );
    expect(workflow).toContain(
      "bash scripts/deploy/assert-runner-boundary.sh staging",
    );
    expect(workflow).not.toContain("secrets.");
  });

  it("bootstraps pinned Node 22 after each runner boundary", () => {
    const captureStart = workflow.indexOf("  capture-production:");
    const adoptionStart = workflow.indexOf("  adopt-staging:");
    const capture = workflow.slice(captureStart, adoptionStart);
    const adoption = workflow.slice(adoptionStart);
    const setupNode =
      "uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020";

    expect(captureStart).toBeGreaterThan(-1);
    expect(adoptionStart).toBeGreaterThan(captureStart);
    for (const source of [capture, adoption]) {
      expect(source.match(/- name: Install Node\.js/gu)).toHaveLength(1);
      expect(source).toContain(setupNode);
      expect(source).toContain("node-version: 22");
    }
    expect(capture.indexOf("assert-runner-boundary.sh production"))
      .toBeLessThan(capture.indexOf(setupNode));
    expect(capture.indexOf(setupNode)).toBeLessThan(
      capture.indexOf("capture-legacy-release.sh"),
    );
    expect(adoption.indexOf("assert-runner-boundary.sh staging"))
      .toBeLessThan(adoption.indexOf(setupNode));
    expect(adoption.indexOf(setupNode)).toBeLessThan(
      adoption.indexOf("adopt-legacy-release.sh"),
    );
  });

  it("signs both capture and final minimal adoption evidence", () => {
    expect(workflow.match(/\bcosign sign-blob\b/gu)).toHaveLength(2);
    expect(workflow).toContain(
      "legacy-production-capture-${{ github.run_id }}-${{ github.run_attempt }}",
    );
    expect(workflow).toContain(
      "legacy-production-adoption-${{ github.run_id }}-${{ github.run_attempt }}",
    );
    expect(workflow).toContain("sha256sum --check SHA256SUMS");
  });

  it("binds reruns to their attempt and rejects an earlier successful run", () => {
    expect(workflow).toContain("GITHUB_RUN_ID: ${{ github.run_id }}");
    expect(workflow).toContain("verify-legacy-history.mjs");
    expect(workflow).toContain("${{ github.run_attempt }}");
  });

  it("pins every third-party action to a full commit SHA", () => {
    for (const line of workflow.split("\n").filter((value) =>
      value.trimStart().startsWith("uses: actions/")
      || value.trimStart().startsWith("uses: sigstore/"))) {
      expect(line).toMatch(/@[a-f0-9]{40}\b/u);
    }
  });
});
