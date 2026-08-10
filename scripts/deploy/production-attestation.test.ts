import { describe, expect, it } from "vitest";

// @ts-expect-error JavaScript deployment helper without declaration file.
import { buildProductionAttestation } from "./production-attestation.mjs";

const valid = {
  releaseSha: "a".repeat(40),
  artifactDigest: `sha256:${"b".repeat(64)}`,
  repository: "duindorpteneu/platform",
  promotionRunId: "101",
  promotionRunAttempt: "1",
  stagingDeployRunId: "99",
  backupArtifactId: "123",
  backupEncryptedSha256: "c".repeat(64),
  promotionEvidenceManifestSha256: `sha256:${"9".repeat(64)}`,
  acceptanceRuns: {
    core: "102",
    phase_b: "103",
    mollie: "104",
    sendgrid: "105",
    restore: "106",
    rollback: "107",
    operations: "108",
  },
  rollbackTargetReleaseSha: "d".repeat(40),
  rollbackTargetArtifactDigest: `sha256:${"e".repeat(64)}`,
  uatActor: "danny-release",
  uatConfirmation: "HUMAN-UAT-PASSED+PROMOTE-PRODUCTION",
  createdAt: "2026-08-03T12:00:00.000Z",
};

describe("production deployment evidence", () => {
  it("bindt live artifact en herstelpunt aan dezelfde promotierun", () => {
    expect(buildProductionAttestation(valid)).toMatchObject({
      environment: "production",
      release_sha: valid.releaseSha,
      artifact_digest: valid.artifactDigest,
      promotion_run_id: 101,
      staging_deploy_run_id: 99,
      backup_artifact_id: 123,
      backup_encrypted_sha256: valid.backupEncryptedSha256,
      schema_version: 3,
      promotion_evidence_manifest_sha256:
        valid.promotionEvidenceManifestSha256,
      legacy_transition: null,
      acceptance_run_ids: {
        phase_b: 103,
        rollback: 107,
      },
      human_uat: {
        confirmed: true,
        actor: "danny-release",
      },
    });
  });

  it("records the one-time legacy transition without weakening normal runs", () => {
    expect(buildProductionAttestation({
      ...valid,
      legacyAdoptionRunId: "109",
      legacyAdoptionEvidenceSha256: `sha256:${"f".repeat(64)}`,
    })).toMatchObject({
      legacy_transition: {
        adoption_run_id: 109,
        capture_evidence_sha256: `sha256:${"f".repeat(64)}`,
      },
    });
    expect(() => buildProductionAttestation({
      ...valid,
      legacyAdoptionRunId: "109",
    })).toThrow("Legacy adoptie-identiteit");
  });

  it.each([
    { artifactDigest: "sha256:short" },
    { backupArtifactId: "0" },
    { backupEncryptedSha256: "short" },
    { promotionEvidenceManifestSha256: "sha256:short" },
    { repository: "invalid" },
  ])("weigert onvolledig of ongebonden bewijs", (patch) => {
    expect(() => buildProductionAttestation({
      ...valid,
      ...patch,
    })).toThrow();
  });
});
