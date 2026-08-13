import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const script = readFileSync(
  new URL("./application-rollback-drill.sh", import.meta.url),
  "utf8",
);
const workflow = readFileSync(
  new URL(
    "../../.github/workflows/staging-rollback-drill.yml",
    import.meta.url,
  ),
  "utf8",
);

describe("staging application rollback drill", () => {
  it("vereist twee verschillende artifactgebonden releases", () => {
    expect(script).toContain(
      "Rollbackdrill vereist een nieuwe candidate naast production.",
    );
    expect(script).toContain("PRODUCTION_ROLLBACK_REVISION");
    expect(script).toContain("PRODUCTION_ROLLBACK_RELEASE_MANIFEST");
    expect(script).toContain(".env.runtime.production-rollback");
    expect(script).not.toContain(
      '"${runtime_directory}/PREVIOUS_REVISION"',
    );
    expect(script).toContain("RELEASE_ARTIFACT_DIGEST");
    expect(script).toContain("previous_artifact_digest");
  });

  it("herstelt de releasecandidate ook via de EXIT-trap", () => {
    expect(script).toContain("trap cleanup EXIT");
    expect(script).toContain("trap 'cleanup 130' INT");
    expect(script).toContain("trap 'cleanup 129' HUP");
    expect(script).toContain("trap 'cleanup 143' TERM");
    expect(script).toContain("if ! restore_current");
    expect(script).toContain("status=70");
    expect(script).not.toContain("up -d --no-build --remove-orphans || true");
  });

  it("serialiseert met stagingdeploy en uploadt exact bewijs", () => {
    expect(workflow).toContain("group: deploy-duindorpteneu-staging");
    expect(workflow).toContain("staging-attestation-rollback-");
    expect(workflow).toContain("needs.preflight.outputs.artifact_digest");
    const boundary = workflow.indexOf(
      "bash scripts/deploy/assert-runner-boundary.sh staging",
    );
    const node = workflow.indexOf(
      "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020",
    );
    const rollback = workflow.indexOf(
      "run: bash scripts/staging/application-rollback-drill.sh",
    );
    expect(node).toBeGreaterThan(boundary);
    expect(rollback).toBeGreaterThan(node);
  });

  it("allows only the signed one-time legacy health bridge", () => {
    expect(script).toContain(
      'legacy_sha="a79c8d843d75e90810ccceb228538c6368d2198b"',
    );
    expect(script).toContain("legacy-adoption-evidence.mjs verify-result");
    expect(script).toContain("legacy-v1-exact-four-fields");
    expect(script).toContain("check-legacy-http.mjs");
    expect(script).toContain("schema_version: 2");
    expect(script).toContain("previous_scheduler_expected=false");
    expect(script).toContain("stop_and_check_scheduler");
    expect(script).toContain(
      'compose "${previous_image}" up -d --no-build app',
    );
    expect(script).toContain(
      "node scripts/deploy/normalize-legacy-runtime.mjs",
    );
  });
});
