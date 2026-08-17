import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

function validSha(value) {
  return typeof value === "string" && /^[a-f0-9]{40}$/u.test(value);
}

function validDigest(value) {
  return typeof value === "string"
    && /^sha256:[a-f0-9]{64}$/u.test(value);
}

export function validateProductionBackupEvidence(value, expected) {
  const sourceFingerprint = createHash("sha256")
    .update(expected.projectRef)
    .digest("hex")
    .slice(0, 16);
  const objectives = value?.objectives;
  const objectivesValid = objectives?.managed_backup_rpo_proven === false
    && Number.isSafeInteger(objectives?.backup_snapshot_age_seconds)
    && Number.isSafeInteger(objectives?.backup_snapshot_age_target_seconds)
    && objectives.backup_snapshot_age_seconds >= 0
    && objectives.backup_snapshot_age_target_seconds > 0
    && objectives.backup_snapshot_age_seconds
      <= objectives.backup_snapshot_age_target_seconds
    && Number.isSafeInteger(objectives?.restore_duration_seconds)
    && Number.isSafeInteger(objectives?.restore_duration_target_seconds)
    && objectives.restore_duration_seconds >= 0
    && objectives.restore_duration_target_seconds > 0
    && objectives.restore_duration_seconds
      <= objectives.restore_duration_target_seconds;
  const startedAt = new Date(value?.started_at).valueOf();
  const backupSnapshotAt = new Date(value?.backup_snapshot_at).valueOf();
  const completedAt = new Date(value?.completed_at).valueOf();
  if (
    !value
    || typeof value !== "object"
    || Array.isArray(value)
    || value.schema_version !== 5
    || value.result !== "passed"
    || value.target !== "production-logical-backup-isolated-restore"
    || value.release_sha !== expected.candidateReleaseSha
    || value.source_release?.release_sha !== expected.sourceReleaseSha
    || value.source_release?.artifact_digest
      !== expected.sourceArtifactDigest
    || value.source_project_fingerprint !== sourceFingerprint
    || value.database?.postgres_major !== 17
    || ![15, 16, 17].includes(value.database?.source_postgres_major)
    || value.database?.contract_mode !== "source"
    || value.database?.candidate_contract_exact !== false
    || value.database?.owner_acl_rls_exact !== true
    || value.database?.schema_definition_exact !== true
    || value.database?.data_content_hmac_exact !== true
    || value.database?.role_contract_exact !== true
    || !/^[a-f0-9]{64}$/u.test(
      value.database?.inventory_sha256 ?? "",
    )
    || value.database?.identity_contract?.hmac_exact !== true
    || value.database?.security_contract?.source_adaptive_rls !== true
    || typeof value.database?.security_contract
      ?.unauthorized_access_denied !== "boolean"
    || !Number.isSafeInteger(
      value.database?.security_contract?.underlying_member_rows,
    )
    || value.database?.security_contract?.unauthorized_member_rows !== 0
    || !Number.isSafeInteger(value.database?.source_migration_count)
    || value.database.source_migration_count < 1
    || !Number.isSafeInteger(value.database?.candidate_migration_count)
    || value.database.source_migration_count
      > value.database.candidate_migration_count
    || value.isolation
      ?.source_and_dump_same_exported_snapshot !== true
    || value.isolation?.target_network !== "none"
    || value.isolation?.published_ports !== 0
    || value.isolation?.provider_configuration !== false
    || value.isolation?.plaintext_dump_uploaded !== false
    || value.isolation?.raw_inventory_uploaded !== false
    || !objectivesValid
    || value.encrypted_backup?.algorithm !== "AES256"
    || !/^[a-f0-9]{64}$/u.test(value.encrypted_backup?.sha256 ?? "")
    || !validSha(expected.candidateReleaseSha)
    || !validSha(expected.sourceReleaseSha)
    || !validDigest(expected.sourceArtifactDigest)
    || !/^[a-z0-9]{20}$/u.test(expected.projectRef)
    || [startedAt, backupSnapshotAt, completedAt].some(Number.isNaN)
    || backupSnapshotAt < startedAt
    || completedAt < backupSnapshotAt
  ) {
    throw new Error("Productionback-upbewijs is ongeldig");
  }
  return value.encrypted_backup.sha256;
}

async function main() {
  const [evidencePath] = process.argv.slice(2);
  if (!evidencePath) {
    throw new Error(
      "Gebruik production-backup-evidence.mjs <bewijs>",
    );
  }
  const checksum = validateProductionBackupEvidence(
    JSON.parse(await readFile(evidencePath, "utf8")),
    {
      candidateReleaseSha: process.env.RELEASE_SHA,
      sourceReleaseSha: process.env.SOURCE_RELEASE_SHA,
      sourceArtifactDigest: process.env.SOURCE_ARTIFACT_DIGEST,
      projectRef: process.env.SUPABASE_PROJECT_REF,
    },
  );
  process.stdout.write(checksum);
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Productionback-upbewijs is ongeldig"}\n`,
    );
    process.exitCode = 1;
  });
}
