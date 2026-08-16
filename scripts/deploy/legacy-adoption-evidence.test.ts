import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js deployment helper.
import * as legacyAdoptionEvidence from "./legacy-adoption-evidence.mjs";
const {
  buildLegacyAdoptionResult,
  buildLegacyCaptureEvidence,
  validateLegacyAdoptionProvenance,
  validateLegacyAdoptionResult,
  validateLegacyCaptureEvidence,
} = legacyAdoptionEvidence;

const legacySha = "a79c8d843d75e90810ccceb228538c6368d2198b";
const digest = (seed: string) => `sha256:${seed.repeat(64)}`;
const manifest = {
  schemaVersion: 2,
  gitSha: legacySha,
  imageTag: `duindorpteneu-app:${legacySha}`,
  imageDigest: digest("a"),
  imageConfigDigest: digest("b"),
  artifactDigest: digest("c"),
  deployedAt: "2026-07-20T15:30:00.000Z",
  environment: "production",
};
const capture = buildLegacyCaptureEvidence({
  manifest,
  manifestSha256: digest("d"),
  recoveredArchiveSha256: digest("e"),
  repository: "duindorpteneu/platform",
  captureWorkflowRunId: 300,
  captureWorkflowRunAttempt: 1,
  captureSource: "local_manifest_image",
  stateBeforeSha256: digest("f"),
  stateAfterSha256: digest("f"),
  productionHealthProvenBeforeAfter: true,
  loopbackHealthProvenBeforeAfter: true,
  capturedAt: "2026-08-03T20:00:00.000Z",
});

describe("one-time legacy adoption evidence", () => {
  it("binds the live production manifest and recovered archive to history", () => {
    expect(validateLegacyCaptureEvidence(
      capture,
      manifest,
      { runId: 300, runAttempt: 1 },
    )).toEqual(capture);
    expect(capture.historic_deploy).toMatchObject({
      run_id: 29754524344,
      artifacts_expired: true,
    });
    expect(capture).toMatchObject({
      schema_version: 2,
      capture_source: "local_manifest_image",
      loopback_health_proven_before_after: true,
      live_container_bound: false,
      local_image_manifest_bound: true,
      production_state_before_sha256: digest("f"),
      production_state_after_sha256: digest("f"),
      provenance_contract:
        "one-time-local-manifest-provenance-exception-v1",
    });
  });

  it.each([
    { legacy_release_sha: "f".repeat(40) },
    { production_health_proven_before_after: false },
    { loopback_health_proven_before_after: false },
    { provenance_contract: "live-container-byte-capture-v1" },
    { recovered_archive_sha256: "sha256:short" },
    { capture_source: "rebuilt_image" },
    { live_container_bound: true },
    { local_image_manifest_bound: false },
    { production_state_after_sha256: digest("0") },
    { historic_deploy: { ...capture.historic_deploy, run_id: 1 } },
  ])("rejects capture drift", (patch) => {
    expect(() => validateLegacyCaptureEvidence(
      { ...capture, ...patch },
      manifest,
    )).toThrow();
  });

  it("binds a restored candidate to the exact capture hash and workflow", () => {
    const captureHash = `sha256:${createHash("sha256")
      .update("capture").digest("hex")}`;
    const result = buildLegacyAdoptionResult({
      repository: "duindorpteneu/platform",
      candidateReleaseSha: "f".repeat(40),
      candidateArtifactDigest: digest("1"),
      captureEvidenceSha256: captureHash,
      adoptionWorkflowRunId: 400,
      adoptionWorkflowRunAttempt: 2,
      restoredCandidate: true,
      legacyHealthProven: true,
      legacySchedulerExpected: false,
      candidateSchedulerHealthProven: true,
      providersDisabled: true,
      adoptedAt: "2026-08-03T21:00:00.000Z",
    });
    expect(validateLegacyAdoptionResult(result, captureHash, {
      candidateReleaseSha: "f".repeat(40),
      candidateArtifactDigest: digest("1"),
      runId: 400,
      runAttempt: 2,
      notBefore: "2026-08-03T20:59:00.000Z",
      notAfter: "2026-08-03T21:01:00.000Z",
    })).toEqual(result);
    expect(result).toMatchObject({
      schema_version: 2,
      legacy_scheduler_expected: false,
      candidate_scheduler_health_proven: true,
    });
  });

  it("rejects timestamps outside the workflow window", () => {
    expect(() => validateLegacyCaptureEvidence(capture, manifest, {
      runId: 300,
      notBefore: "2026-08-03T20:00:01.000Z",
      notAfter: "2026-08-03T21:00:00.000Z",
    })).toThrow();
  });

  it("reuses only the signed legacy provenance for a later candidate drill", () => {
    const captureHash = `sha256:${createHash("sha256")
      .update("capture").digest("hex")}`;
    const result = buildLegacyAdoptionResult({
      repository: "duindorpteneu/platform",
      candidateReleaseSha: "f".repeat(40),
      candidateArtifactDigest: digest("1"),
      captureEvidenceSha256: captureHash,
      adoptionWorkflowRunId: 400,
      adoptionWorkflowRunAttempt: 2,
      restoredCandidate: true,
      legacyHealthProven: true,
      legacySchedulerExpected: false,
      candidateSchedulerHealthProven: true,
      providersDisabled: true,
      adoptedAt: "2026-08-03T21:00:00.000Z",
    });
    expect(validateLegacyAdoptionProvenance(result, captureHash, {
      runId: 400,
      runAttempt: 2,
    })).toEqual(result);
    expect(() => validateLegacyAdoptionProvenance(result, captureHash, {
      runId: 401,
      runAttempt: 2,
    })).toThrow();
  });
});
