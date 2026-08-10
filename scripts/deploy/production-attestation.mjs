import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const positiveInteger = (value) => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};

export function buildProductionAttestation(input) {
  if (!/^[a-f0-9]{40}$/u.test(input.releaseSha ?? "")) {
    throw new Error("Release-SHA is ongeldig");
  }
  if (!/^sha256:[a-f0-9]{64}$/u.test(input.artifactDigest ?? "")) {
    throw new Error("Artefactdigest is ongeldig");
  }
  if (!/^[a-f0-9]{64}$/u.test(input.backupEncryptedSha256 ?? "")) {
    throw new Error("Backupchecksum is ongeldig");
  }
  if (
    !/^sha256:[a-f0-9]{64}$/u.test(
      input.promotionEvidenceManifestSha256 ?? "",
    )
  ) {
    throw new Error("Promotiebewijsmanifestchecksum is ongeldig");
  }
  if (
    !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/u
      .test(input.repository ?? "")
  ) {
    throw new Error("Repository is ongeldig");
  }
  const promotionRunId = positiveInteger(input.promotionRunId);
  const promotionRunAttempt = positiveInteger(input.promotionRunAttempt);
  const stagingDeployRunId = positiveInteger(input.stagingDeployRunId);
  const backupArtifactId = positiveInteger(input.backupArtifactId);
  const acceptanceRuns = Object.fromEntries(
    Object.entries(input.acceptanceRuns ?? {}).map(([key, value]) => [
      key,
      positiveInteger(value),
    ]),
  );
  const expectedAcceptanceKeys = [
    "core",
    "mollie",
    "operations",
    "phase_b",
    "restore",
    "rollback",
    "sendgrid",
  ];
  if (
    !promotionRunId
    || !promotionRunAttempt
    || !stagingDeployRunId
    || !backupArtifactId
    || Object.keys(acceptanceRuns).sort().join(",")
      !== expectedAcceptanceKeys.sort().join(",")
    || Object.values(acceptanceRuns).some((value) => !value)
    || !/^[a-f0-9]{40}$/u.test(input.rollbackTargetReleaseSha ?? "")
    || !/^sha256:[a-f0-9]{64}$/u.test(
      input.rollbackTargetArtifactDigest ?? "",
    )
    || !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/u
      .test(input.uatActor ?? "")
    || input.uatConfirmation
      !== "HUMAN-UAT-PASSED+PROMOTE-PRODUCTION"
  ) {
    throw new Error("Workflow- of backupidentiteit is ongeldig");
  }
  const legacyAdoptionRunId = input.legacyAdoptionRunId
    ? positiveInteger(input.legacyAdoptionRunId)
    : null;
  const legacyAdoptionEvidenceSha256 =
    input.legacyAdoptionEvidenceSha256 || null;
  if (
    (legacyAdoptionRunId === null)
      !== (legacyAdoptionEvidenceSha256 === null)
    || (
      legacyAdoptionEvidenceSha256 !== null
      && !/^sha256:[a-f0-9]{64}$/u.test(
        legacyAdoptionEvidenceSha256,
      )
    )
  ) throw new Error("Legacy adoptie-identiteit is ongeldig");
  const createdAt = new Date(input.createdAt ?? Date.now());
  if (Number.isNaN(createdAt.valueOf())) {
    throw new Error("Attestationtijd is ongeldig");
  }
  return {
    schema_version: 3,
    result: "passed",
    environment: "production",
    release_sha: input.releaseSha,
    artifact_digest: input.artifactDigest,
    repository: input.repository,
    promotion_run_id: promotionRunId,
    promotion_run_attempt: promotionRunAttempt,
    staging_deploy_run_id: stagingDeployRunId,
    acceptance_run_ids: acceptanceRuns,
    promotion_evidence_manifest_sha256:
      input.promotionEvidenceManifestSha256,
    rollback_target: {
      release_sha: input.rollbackTargetReleaseSha,
      artifact_digest: input.rollbackTargetArtifactDigest,
    },
    legacy_transition: legacyAdoptionRunId === null
      ? null
      : {
          adoption_run_id: legacyAdoptionRunId,
          capture_evidence_sha256: legacyAdoptionEvidenceSha256,
        },
    human_uat: {
      confirmed: true,
      actor: input.uatActor,
    },
    backup_artifact_id: backupArtifactId,
    backup_encrypted_sha256: input.backupEncryptedSha256,
    created_at: createdAt.toISOString(),
  };
}

async function main() {
  const [
    target,
    releaseSha,
    artifactDigest,
    stagingDeployRunId,
    backupArtifactId,
    backupEncryptedSha256,
    promotionEvidenceManifestPath,
  ] = process.argv.slice(2);
  if (!target || !promotionEvidenceManifestPath) {
    throw new Error(
      "Gebruik: production-attestation.mjs <pad> <sha> <digest> "
      + "<staging-run> <backup-artifact-id> <backup-checksum> "
      + "<promotiebewijsmanifest>",
    );
  }
  const promotionEvidenceManifestSha256 =
    `sha256:${createHash("sha256")
      .update(await readFile(promotionEvidenceManifestPath))
      .digest("hex")}`;
  const attestation = buildProductionAttestation({
    releaseSha,
    artifactDigest,
    repository: process.env.GITHUB_REPOSITORY,
    promotionRunId: process.env.GITHUB_RUN_ID,
    promotionRunAttempt: process.env.GITHUB_RUN_ATTEMPT,
    stagingDeployRunId,
    backupArtifactId,
    backupEncryptedSha256,
    promotionEvidenceManifestSha256,
    acceptanceRuns: {
      core: process.env.CORE_ACCEPTANCE_RUN_ID,
      phase_b: process.env.PHASE_B_ACCEPTANCE_RUN_ID,
      mollie: process.env.MOLLIE_ACCEPTANCE_RUN_ID,
      sendgrid: process.env.SENDGRID_ACCEPTANCE_RUN_ID,
      restore: process.env.RESTORE_ACCEPTANCE_RUN_ID,
      rollback: process.env.ROLLBACK_ACCEPTANCE_RUN_ID,
      operations: process.env.OPERATIONS_ACCEPTANCE_RUN_ID,
    },
    rollbackTargetReleaseSha: process.env.ROLLBACK_TARGET_RELEASE_SHA,
    rollbackTargetArtifactDigest:
      process.env.ROLLBACK_TARGET_ARTIFACT_DIGEST,
    uatActor: process.env.UAT_ACTOR,
    uatConfirmation: process.env.UAT_CONFIRMATION,
    legacyAdoptionRunId: process.env.LEGACY_ADOPTION_RUN_ID,
    legacyAdoptionEvidenceSha256:
      process.env.LEGACY_ADOPTION_EVIDENCE_SHA256,
  });
  await writeFile(
    target,
    `${JSON.stringify(attestation, null, 2)}\n`,
    { mode: 0o600 },
  );
  process.stdout.write("Productieattestation is aangemaakt.\n");
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error
        ? error.message
        : "Productieattestation kon niet worden gemaakt"}\n`,
    );
    process.exitCode = 1;
  });
}
