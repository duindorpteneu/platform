import { describe, expect, it } from "vitest";
// @ts-expect-error JavaScript deployment helper without declaration file.
import { validateRollbackEvidence } from "./rollback-evidence.mjs";

function manifest(seed: string) {
  const sha = seed.repeat(40);
  return {
    schemaVersion: 2,
    gitSha: sha,
    imageTag: `duindorpteneu-app:${sha}`,
    imageDigest: `sha256:${seed.repeat(64)}`,
    imageConfigDigest: `sha256:${seed.toUpperCase().toLowerCase().repeat(64)}`,
    artifactDigest: `sha256:${seed.repeat(64)}`,
  };
}

const candidate = manifest("a");
const production = manifest("b");

function evidence() {
  return {
    schema_version: 2,
    result: "passed",
    environment: "staging",
    current_release_sha: candidate.gitSha,
    current_oci_digest: candidate.imageDigest,
    current_config_digest: candidate.imageConfigDigest,
    current_artifact_digest: candidate.artifactDigest,
    previous_release_sha: production.gitSha,
    previous_oci_digest: production.imageDigest,
    previous_config_digest: production.imageConfigDigest,
    previous_artifact_digest: production.artifactDigest,
    previous_health_contract: "artifact-v2",
    previous_scheduler_expected: true,
    legacy_adoption_evidence_sha256: null,
    legacy_adoption_run_id: null,
    restored_current_release: true,
    app_health_proven: true,
    scheduler_health_proven: true,
    rollback_provider_send_disabled: true,
    database_rollback_attempted: false,
    created_at: "2026-08-03T20:00:00.000Z",
  };
}

describe("production rollback target evidence", () => {
  it("binds the candidate and actual production target completely", () => {
    expect(
      validateRollbackEvidence(evidence(), candidate, production),
    ).toEqual(evidence());
  });

  it("rejects a different production image with the same release SHA", () => {
    const changed = {
      ...production,
      imageConfigDigest: `sha256:${"c".repeat(64)}`,
    };
    expect(() =>
      validateRollbackEvidence(evidence(), candidate, changed))
      .toThrow("actuele productionrelease");
  });

  it("accepts the single legacy health contract only with adoption evidence", () => {
    const legacyProduction = {
      ...production,
      gitSha: "a79c8d843d75e90810ccceb228538c6368d2198b",
      imageTag:
        "duindorpteneu-app:a79c8d843d75e90810ccceb228538c6368d2198b",
    };
    const legacyEvidence = {
      ...evidence(),
      previous_release_sha: legacyProduction.gitSha,
      previous_oci_digest: legacyProduction.imageDigest,
      previous_config_digest: legacyProduction.imageConfigDigest,
      previous_artifact_digest: legacyProduction.artifactDigest,
      previous_health_contract: "legacy-v1-exact-four-fields",
      previous_scheduler_expected: false,
      legacy_adoption_evidence_sha256: `sha256:${"e".repeat(64)}`,
      legacy_adoption_run_id: 12345,
    };
    expect(validateRollbackEvidence(
      legacyEvidence,
      candidate,
      legacyProduction,
    )).toEqual(legacyEvidence);
    expect(() => validateRollbackEvidence({
      ...legacyEvidence,
      legacy_adoption_evidence_sha256: null,
    }, candidate, legacyProduction)).toThrow("healthcontractbrug");
  });
});
