import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { LEGACY_PRODUCTION_SHA } from "./legacy-health-identity.mjs";

const HISTORIC_RUN_ID = 29754524344;
const HISTORIC_ARTIFACTS = {
  image: {
    id: 8466202224,
    name: `release-image-${LEGACY_PRODUCTION_SHA}`,
  },
  staging_manifest: {
    id: 8466245309,
    name: `staging-release-${LEGACY_PRODUCTION_SHA}`,
  },
};
const CAPTURE_SOURCES = new Set([
  "running_container",
  "local_manifest_image",
]);

function validDigest(value) {
  return typeof value === "string"
    && /^sha256:[a-f0-9]{64}$/u.test(value);
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function validManifest(value) {
  return value
    && typeof value === "object"
    && !Array.isArray(value)
    && value.schemaVersion === 2
    && value.gitSha === LEGACY_PRODUCTION_SHA
    && value.imageTag === `duindorpteneu-app:${LEGACY_PRODUCTION_SHA}`
    && validDigest(value.imageDigest)
    && validDigest(value.imageConfigDigest)
    && validDigest(value.artifactDigest)
    && value.environment === "production"
    && !Number.isNaN(new Date(value.deployedAt).valueOf());
}

function canonicalHash(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function captureProvenanceContract(source) {
  if (source === "running_container") {
    return "live-container-byte-capture-v1";
  }
  if (source === "local_manifest_image") {
    return "one-time-local-manifest-provenance-exception-v1";
  }
  return null;
}

function timestampWithin(value, expected) {
  const timestamp = new Date(value).valueOf();
  const notBefore = expected.notBefore === undefined
    ? null
    : new Date(expected.notBefore).valueOf();
  const notAfter = expected.notAfter === undefined
    ? null
    : new Date(expected.notAfter).valueOf();
  return Number.isFinite(timestamp)
    && (notBefore === null
      || (Number.isFinite(notBefore) && timestamp >= notBefore))
    && (notAfter === null
      || (Number.isFinite(notAfter) && timestamp <= notAfter));
}

async function fileHash(path) {
  return canonicalHash(await readFile(path));
}

export function buildLegacyCaptureEvidence(input) {
  if (
    !validManifest(input.manifest)
    || !validDigest(input.manifestSha256)
    || !validDigest(input.recoveredArchiveSha256)
    || input.repository !== "duindorpteneu/platform"
    || !positiveInteger(input.captureWorkflowRunId)
    || !positiveInteger(input.captureWorkflowRunAttempt)
    || !CAPTURE_SOURCES.has(input.captureSource)
    || !validDigest(input.stateBeforeSha256)
    || input.stateBeforeSha256 !== input.stateAfterSha256
    || input.productionHealthProvenBeforeAfter !== true
    || input.loopbackHealthProvenBeforeAfter !== true
  ) throw new Error("Legacy capturebewijs is ongeldig");
  const capturedAt = new Date(input.capturedAt ?? Date.now());
  if (Number.isNaN(capturedAt.valueOf())) {
    throw new Error("Legacy capturetijd is ongeldig");
  }
  return {
    schema_version: 2,
    result: "passed",
    repository: input.repository,
    legacy_release_sha: LEGACY_PRODUCTION_SHA,
    production_health_contract: "legacy-v1-exact-four-fields",
    production_health_proven_before_after: true,
    loopback_health_proven_before_after: true,
    provenance_contract:
      captureProvenanceContract(input.captureSource),
    live_container_bound:
      input.captureSource === "running_container",
    local_image_manifest_bound: true,
    production_state_before_sha256: input.stateBeforeSha256,
    production_state_after_sha256: input.stateAfterSha256,
    historic_deploy: {
      workflow_path: ".github/workflows/deploy.yml",
      run_id: HISTORIC_RUN_ID,
      artifacts_expired: true,
      artifacts: HISTORIC_ARTIFACTS,
    },
    legacy_manifest: input.manifest,
    legacy_manifest_sha256: input.manifestSha256,
    recovered_archive_sha256: input.recoveredArchiveSha256,
    capture_source: input.captureSource,
    capture_workflow_run_id: positiveInteger(input.captureWorkflowRunId),
    capture_workflow_run_attempt:
      positiveInteger(input.captureWorkflowRunAttempt),
    captured_at: capturedAt.toISOString(),
  };
}

export function validateLegacyCaptureEvidence(
  value,
  manifest,
  expected = {},
) {
  const canonical = buildLegacyCaptureEvidence({
    manifest: value?.legacy_manifest,
    manifestSha256: value?.legacy_manifest_sha256,
    recoveredArchiveSha256: value?.recovered_archive_sha256,
    repository: value?.repository,
    captureWorkflowRunId: value?.capture_workflow_run_id,
    captureWorkflowRunAttempt: value?.capture_workflow_run_attempt,
    captureSource: value?.capture_source,
    stateBeforeSha256:
      value?.production_state_before_sha256,
    stateAfterSha256:
      value?.production_state_after_sha256,
    productionHealthProvenBeforeAfter:
      value?.production_health_proven_before_after,
    loopbackHealthProvenBeforeAfter:
      value?.loopback_health_proven_before_after,
    capturedAt: value?.captured_at,
  });
  if (
    JSON.stringify(value) !== JSON.stringify(canonical)
    || JSON.stringify(manifest) !== JSON.stringify(canonical.legacy_manifest)
    || (expected.runId !== undefined
      && canonical.capture_workflow_run_id
        !== positiveInteger(expected.runId))
    || (expected.runAttempt !== undefined
      && canonical.capture_workflow_run_attempt
        !== positiveInteger(expected.runAttempt))
    || !timestampWithin(canonical.captured_at, expected)
  ) throw new Error("Legacy capturebewijs wijkt af");
  return canonical;
}

export function buildLegacyAdoptionResult(input) {
  if (
    input.repository !== "duindorpteneu/platform"
    || !/^[a-f0-9]{40}$/u.test(input.candidateReleaseSha ?? "")
    || !validDigest(input.candidateArtifactDigest)
    || !validDigest(input.captureEvidenceSha256)
    || !positiveInteger(input.adoptionWorkflowRunId)
    || !positiveInteger(input.adoptionWorkflowRunAttempt)
    || input.restoredCandidate !== true
    || input.legacyHealthProven !== true
    || input.legacySchedulerExpected !== false
    || input.candidateSchedulerHealthProven !== true
    || input.providersDisabled !== true
  ) throw new Error("Legacy adoptiresultaat is ongeldig");
  const adoptedAt = new Date(input.adoptedAt ?? Date.now());
  if (Number.isNaN(adoptedAt.valueOf())) {
    throw new Error("Legacy adoptietijd is ongeldig");
  }
  return {
    schema_version: 2,
    result: "passed",
    repository: input.repository,
    candidate_release_sha: input.candidateReleaseSha,
    candidate_artifact_digest: input.candidateArtifactDigest,
    legacy_release_sha: LEGACY_PRODUCTION_SHA,
    capture_evidence_sha256: input.captureEvidenceSha256,
    adoption_workflow_run_id: positiveInteger(input.adoptionWorkflowRunId),
    adoption_workflow_run_attempt:
      positiveInteger(input.adoptionWorkflowRunAttempt),
    restored_candidate: true,
    legacy_health_proven: true,
    legacy_scheduler_expected: false,
    candidate_scheduler_health_proven: true,
    providers_disabled: true,
    database_rollback_attempted: false,
    adopted_at: adoptedAt.toISOString(),
  };
}

export function validateLegacyAdoptionResult(
  value,
  captureEvidenceSha256,
  expected,
) {
  const canonical = buildLegacyAdoptionResult({
    repository: value?.repository,
    candidateReleaseSha: value?.candidate_release_sha,
    candidateArtifactDigest: value?.candidate_artifact_digest,
    captureEvidenceSha256: value?.capture_evidence_sha256,
    adoptionWorkflowRunId: value?.adoption_workflow_run_id,
    adoptionWorkflowRunAttempt: value?.adoption_workflow_run_attempt,
    restoredCandidate: value?.restored_candidate,
    legacyHealthProven: value?.legacy_health_proven,
    legacySchedulerExpected: value?.legacy_scheduler_expected,
    candidateSchedulerHealthProven:
      value?.candidate_scheduler_health_proven,
    providersDisabled: value?.providers_disabled,
    adoptedAt: value?.adopted_at,
  });
  if (
    JSON.stringify(value) !== JSON.stringify(canonical)
    || canonical.capture_evidence_sha256 !== captureEvidenceSha256
    || canonical.candidate_release_sha !== expected.candidateReleaseSha
    || canonical.candidate_artifact_digest !== expected.candidateArtifactDigest
    || canonical.adoption_workflow_run_id !== positiveInteger(expected.runId)
    || (expected.runAttempt !== undefined
      && canonical.adoption_workflow_run_attempt
        !== positiveInteger(expected.runAttempt))
    || !timestampWithin(canonical.adopted_at, expected)
  ) throw new Error("Legacy adoptiresultaat wijkt af");
  return canonical;
}

export function validateLegacyAdoptionProvenance(
  value,
  captureEvidenceSha256,
  expected,
) {
  return validateLegacyAdoptionResult(
    value,
    captureEvidenceSha256,
    {
      candidateReleaseSha: value?.candidate_release_sha,
      candidateArtifactDigest: value?.candidate_artifact_digest,
      runId: expected.runId,
      runAttempt: expected.runAttempt,
      notBefore: expected.notBefore,
      notAfter: expected.notAfter,
    },
  );
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === "create-capture") {
    const [manifestPath, archivePath, outputPath] = args;
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    const evidence = buildLegacyCaptureEvidence({
      manifest,
      manifestSha256: await fileHash(manifestPath),
      recoveredArchiveSha256: await fileHash(archivePath),
      repository: process.env.GITHUB_REPOSITORY,
      captureWorkflowRunId: process.env.GITHUB_RUN_ID,
      captureWorkflowRunAttempt: process.env.GITHUB_RUN_ATTEMPT,
      captureSource: process.env.LEGACY_CAPTURE_SOURCE,
      stateBeforeSha256:
        process.env.LEGACY_CAPTURE_STATE_BEFORE_SHA256,
      stateAfterSha256:
        process.env.LEGACY_CAPTURE_STATE_AFTER_SHA256,
      productionHealthProvenBeforeAfter: true,
      loopbackHealthProvenBeforeAfter: true,
    });
    await writeFile(
      outputPath,
      `${JSON.stringify(evidence, null, 2)}\n`,
      { mode: 0o600 },
    );
    return;
  }
  if (command === "verify-capture") {
    const [evidencePath, manifestPath, archivePath] = args;
    const evidenceBytes = await readFile(evidencePath);
    const evidence = JSON.parse(evidenceBytes);
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    validateLegacyCaptureEvidence(evidence, manifest);
    if (
      evidence.legacy_manifest_sha256 !== await fileHash(manifestPath)
      || (archivePath
        && evidence.recovered_archive_sha256 !== await fileHash(archivePath))
    ) throw new Error("Legacy capturebestanden wijken af");
    process.stdout.write(canonicalHash(evidenceBytes));
    return;
  }
  if (command === "create-result") {
    const [capturePath, candidateManifestPath, outputPath] = args;
    const captureBytes = await readFile(capturePath);
    const candidate = JSON.parse(
      await readFile(candidateManifestPath, "utf8"),
    );
    const result = buildLegacyAdoptionResult({
      repository: process.env.GITHUB_REPOSITORY,
      candidateReleaseSha: candidate.gitSha,
      candidateArtifactDigest: candidate.artifactDigest,
      captureEvidenceSha256: canonicalHash(captureBytes),
      adoptionWorkflowRunId: process.env.GITHUB_RUN_ID,
      adoptionWorkflowRunAttempt: process.env.GITHUB_RUN_ATTEMPT,
      restoredCandidate: true,
      legacyHealthProven: true,
      legacySchedulerExpected: false,
      candidateSchedulerHealthProven: true,
      providersDisabled: true,
    });
    await writeFile(
      outputPath,
      `${JSON.stringify(result, null, 2)}\n`,
      { mode: 0o600 },
    );
    return;
  }
  if (command === "verify-result") {
    const [
      resultPath,
      capturePath,
      candidateManifestPath,
      expectedRunId,
    ] = args;
    const result = JSON.parse(await readFile(resultPath, "utf8"));
    const captureBytes = await readFile(capturePath);
    const candidate = JSON.parse(
      await readFile(candidateManifestPath, "utf8"),
    );
    validateLegacyAdoptionResult(
      result,
      canonicalHash(captureBytes),
      {
        candidateReleaseSha: candidate.gitSha,
        candidateArtifactDigest: candidate.artifactDigest,
        runId: expectedRunId,
      },
    );
    process.stdout.write(canonicalHash(captureBytes));
    return;
  }
  if (command === "verify-provenance") {
    const [
      resultPath,
      capturePath,
      expectedRunId,
      expectedRunAttempt,
    ] = args;
    const result = JSON.parse(await readFile(resultPath, "utf8"));
    const captureBytes = await readFile(capturePath);
    const capture = JSON.parse(captureBytes);
    const expected = {
      runId: expectedRunId,
      ...(expectedRunAttempt ? { runAttempt: expectedRunAttempt } : {}),
    };
    validateLegacyCaptureEvidence(
      capture,
      capture?.legacy_manifest,
      expected,
    );
    validateLegacyAdoptionProvenance(
      result,
      canonicalHash(captureBytes),
      expected,
    );
    process.stdout.write(canonicalHash(captureBytes));
    return;
  }
  throw new Error(
    "Gebruik legacy-adoption-evidence.mjs "
    + "create-capture|verify-capture|create-result|verify-result"
    + "|verify-provenance ...",
  );
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Legacy bewijs is ongeldig"}\n`,
    );
    process.exitCode = 1;
  });
}
