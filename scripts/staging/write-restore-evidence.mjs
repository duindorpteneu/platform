import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

function integer(value, name) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${name} is geen geldig geheel getal`);
  }
  return parsed;
}

function isoTimestamp(value, name) {
  const date = new Date(required({ [name]: value }, name));
  if (Number.isNaN(date.valueOf())) {
    throw new Error(`${name} is geen geldige tijd`);
  }
  return date.toISOString();
}

function exactKeys(value, expected) {
  return value
    && typeof value === "object"
    && !Array.isArray(value)
    && Object.keys(value).sort().join(",")
      === [...expected].sort().join(",");
}

const VERIFICATION_KEYS = [
  "admin_count",
  "auth_user_count",
  "candidate_migration_count",
  "column_count",
  "contract_mode",
  "contract_version",
  "data_hmac_exact",
  "function_count",
  "identity_hmac_exact",
  "inventory_sha256",
  "owner_acl_rls_exact",
  "policy_count",
  "postgres_major",
  "relation_count",
  "result",
  "role_contract_exact",
  "schema_definition_exact",
  "sequence_count",
  "source_migration_count",
  "staff_count",
  "trigger_count",
  "type_count",
  "unauthorized_member_access_denied",
  "unauthorized_member_rows",
  "underlying_member_rows",
  "view_count",
];

export function buildRestoreEvidence(raw, values) {
  const releaseSha = required(values, "RELEASE_SHA");
  const sourceReleaseSha = required(values, "RESTORE_SOURCE_RELEASE_SHA");
  const sourceArtifactDigest = required(
    values,
    "RESTORE_SOURCE_ARTIFACT_DIGEST",
  );
  const projectRef = required(values, "SUPABASE_PROJECT_REF");
  const targetEnvironment = required(values, "RESTORE_TARGET_ENVIRONMENT");
  const contractMode = required(values, "RESTORE_CONTRACT_MODE");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) {
    throw new Error("RELEASE_SHA is ongeldig");
  }
  if (!/^[a-f0-9]{40}$/u.test(sourceReleaseSha)) {
    throw new Error("RESTORE_SOURCE_RELEASE_SHA is ongeldig");
  }
  if (!/^sha256:[a-f0-9]{64}$/u.test(sourceArtifactDigest)) {
    throw new Error("RESTORE_SOURCE_ARTIFACT_DIGEST is ongeldig");
  }
  if (!/^[a-z0-9]{20}$/u.test(projectRef)) {
    throw new Error("SUPABASE_PROJECT_REF is ongeldig");
  }
  if (!["staging", "production"].includes(targetEnvironment)) {
    throw new Error("RESTORE_TARGET_ENVIRONMENT is ongeldig");
  }
  const expectedProjectRef = targetEnvironment === "staging"
    ? "dxbdjtbyghsovlrdcwcr"
    : "wobcbufmmputydtzemyu";
  const expectedContractMode = targetEnvironment === "staging"
    ? "current"
    : "source";
  if (
    projectRef !== expectedProjectRef
    || contractMode !== expectedContractMode
  ) {
    throw new Error("Restorecontract hoort niet bij de doelomgeving");
  }
  const encryptedSha256 = values.RESTORE_ENCRYPTED_SHA256?.trim() ?? "";
  if (
    targetEnvironment === "production"
    && !/^[a-f0-9]{64}$/u.test(encryptedSha256)
  ) {
    throw new Error("Productieback-up is niet versleuteld");
  }
  if (
    !exactKeys(raw, VERIFICATION_KEYS)
    || raw.contract_version !== 2
    || raw.result !== "passed"
    || raw.contract_mode !== contractMode
    || raw.postgres_major !== 17
    || !/^[a-f0-9]{64}$/u.test(raw.inventory_sha256)
    || raw.owner_acl_rls_exact !== true
    || raw.schema_definition_exact !== true
    || raw.data_hmac_exact !== true
    || raw.role_contract_exact !== true
    || raw.identity_hmac_exact !== true
    || raw.unauthorized_member_rows !== 0
    || typeof raw.unauthorized_member_access_denied !== "boolean"
  ) {
    throw new Error("Restoreverificatie is ongeldig");
  }
  const counts = Object.fromEntries([
    "source_migration_count",
    "candidate_migration_count",
    "relation_count",
    "column_count",
    "type_count",
    "view_count",
    "sequence_count",
    "function_count",
    "policy_count",
    "trigger_count",
    "underlying_member_rows",
    "auth_user_count",
    "staff_count",
    "admin_count",
  ].map((name) => [name, integer(raw[name], name)]));
  if (
    counts.source_migration_count < 1
    || counts.source_migration_count > counts.candidate_migration_count
    || counts.admin_count > counts.staff_count
    || (
      contractMode === "current"
      && counts.source_migration_count !== counts.candidate_migration_count
    )
  ) {
    throw new Error("Restoreverificatie bevat ongeldige tellingen");
  }

  const backupSnapshotAgeSeconds = integer(
    values.BACKUP_SNAPSHOT_AGE_SECONDS,
    "BACKUP_SNAPSHOT_AGE_SECONDS",
  );
  const restoreDurationSeconds = integer(
    values.RESTORE_DURATION_SECONDS,
    "RESTORE_DURATION_SECONDS",
  );
  const backupSnapshotAgeTargetSeconds = 24 * 60 * 60;
  const restoreDurationTargetSeconds = 4 * 60 * 60;
  if (backupSnapshotAgeSeconds > backupSnapshotAgeTargetSeconds) {
    throw new Error("De gebruikte back-upsnapshot is ouder dan 24 uur");
  }
  if (restoreDurationSeconds > restoreDurationTargetSeconds) {
    throw new Error("De technische restore-oefening duurt langer dan 4 uur");
  }
  const startedAt = isoTimestamp(values.STARTED_AT, "STARTED_AT");
  const backupSnapshotAt = isoTimestamp(
    values.BACKUP_SNAPSHOT_AT,
    "BACKUP_SNAPSHOT_AT",
  );
  const completedAt = isoTimestamp(values.COMPLETED_AT, "COMPLETED_AT");
  if (
    new Date(backupSnapshotAt).valueOf() < new Date(startedAt).valueOf()
    || new Date(completedAt).valueOf() < new Date(backupSnapshotAt).valueOf()
  ) {
    throw new Error("Restorebewijs bevat een onmogelijke tijdsvolgorde");
  }

  return {
    schema_version: 4,
    result: "passed",
    target: `${targetEnvironment}-logical-backup-isolated-restore`,
    release_sha: releaseSha,
    source_release: {
      release_sha: sourceReleaseSha,
      artifact_digest: sourceArtifactDigest,
    },
    source_project_fingerprint: createHash("sha256")
      .update(projectRef).digest("hex").slice(0, 16),
    started_at: startedAt,
    backup_snapshot_at: backupSnapshotAt,
    completed_at: completedAt,
    objectives: {
      managed_backup_rpo_proven: false,
      backup_snapshot_age_seconds: backupSnapshotAgeSeconds,
      backup_snapshot_age_target_seconds: backupSnapshotAgeTargetSeconds,
      restore_duration_seconds: restoreDurationSeconds,
      restore_duration_target_seconds: restoreDurationTargetSeconds,
    },
    database: {
      postgres_major: 17,
      contract_mode: contractMode,
      candidate_contract_exact: contractMode === "current",
      source_migration_count: counts.source_migration_count,
      candidate_migration_count: counts.candidate_migration_count,
      inventory_sha256: raw.inventory_sha256,
      object_counts: {
        relations: counts.relation_count,
        columns: counts.column_count,
        types: counts.type_count,
        views: counts.view_count,
        sequences: counts.sequence_count,
        functions: counts.function_count,
        policies: counts.policy_count,
        triggers: counts.trigger_count,
      },
      owner_acl_rls_exact: true,
      schema_definition_exact: true,
      data_content_hmac_exact: true,
      role_contract_exact: true,
      identity_contract: {
        hmac_exact: true,
        auth_user_count: counts.auth_user_count,
        staff_count: counts.staff_count,
        admin_count: counts.admin_count,
      },
      security_contract: {
        source_adaptive_rls: true,
        underlying_member_rows: counts.underlying_member_rows,
        unauthorized_member_rows: 0,
        unauthorized_access_denied:
          raw.unauthorized_member_access_denied,
      },
    },
    isolation: {
      source_and_dump_same_exported_snapshot: true,
      target_network: "none",
      published_ports: 0,
      provider_configuration: false,
      plaintext_dump_uploaded: false,
      raw_inventory_uploaded: false,
    },
    encrypted_backup: targetEnvironment === "production"
      ? {
          algorithm: "AES256",
          sha256: encryptedSha256,
        }
      : null,
  };
}

export function validateRestoreEvidence(value, {
  releaseSha,
  artifactDigest,
  targetEnvironment = "staging",
} = {}) {
  const topLevelKeys = [
    "backup_snapshot_at",
    "completed_at",
    "database",
    "encrypted_backup",
    "isolation",
    "objectives",
    "release_sha",
    "result",
    "schema_version",
    "source_project_fingerprint",
    "source_release",
    "started_at",
    "target",
  ];
  const expectedProjectRef = targetEnvironment === "staging"
    ? "dxbdjtbyghsovlrdcwcr"
    : "wobcbufmmputydtzemyu";
  const expectedFingerprint = createHash("sha256")
    .update(expectedProjectRef).digest("hex").slice(0, 16);
  const timestamps = [
    value?.started_at,
    value?.backup_snapshot_at,
    value?.completed_at,
  ].map((timestamp) => new Date(timestamp).valueOf());
  const database = value?.database;
  const identity = database?.identity_contract;
  const security = database?.security_contract;
  const counts = database?.object_counts;
  const objectives = value?.objectives;
  const isolation = value?.isolation;
  if (
    !exactKeys(value, topLevelKeys)
    || value.schema_version !== 4
    || value.result !== "passed"
    || value.target
      !== `${targetEnvironment}-logical-backup-isolated-restore`
    || value.release_sha !== releaseSha
    || !exactKeys(value.source_release, [
      "artifact_digest",
      "release_sha",
    ])
    || value.source_release?.release_sha !== releaseSha
    || value.source_release?.artifact_digest !== artifactDigest
    || value.source_project_fingerprint !== expectedFingerprint
    || timestamps.some(Number.isNaN)
    || timestamps[0] > timestamps[1]
    || timestamps[1] > timestamps[2]
    || !exactKeys(objectives, [
      "backup_snapshot_age_seconds",
      "backup_snapshot_age_target_seconds",
      "managed_backup_rpo_proven",
      "restore_duration_seconds",
      "restore_duration_target_seconds",
    ])
    || objectives?.managed_backup_rpo_proven !== false
    || !Number.isSafeInteger(objectives?.backup_snapshot_age_seconds)
    || objectives.backup_snapshot_age_seconds < 0
    || objectives.backup_snapshot_age_target_seconds !== 86_400
    || objectives.backup_snapshot_age_seconds
      > objectives.backup_snapshot_age_target_seconds
    || !Number.isSafeInteger(objectives?.restore_duration_seconds)
    || objectives.restore_duration_seconds < 0
    || objectives.restore_duration_target_seconds !== 14_400
    || objectives.restore_duration_seconds
      > objectives.restore_duration_target_seconds
    || !exactKeys(database, [
      "candidate_contract_exact",
      "candidate_migration_count",
      "contract_mode",
      "data_content_hmac_exact",
      "identity_contract",
      "inventory_sha256",
      "object_counts",
      "owner_acl_rls_exact",
      "postgres_major",
      "role_contract_exact",
      "schema_definition_exact",
      "security_contract",
      "source_migration_count",
    ])
    || database?.postgres_major !== 17
    || database?.contract_mode
      !== (targetEnvironment === "staging" ? "current" : "source")
    || database?.candidate_contract_exact
      !== (targetEnvironment === "staging")
    || !Number.isSafeInteger(database?.source_migration_count)
    || database.source_migration_count < 1
    || !Number.isSafeInteger(database?.candidate_migration_count)
    || database.candidate_migration_count
      < database.source_migration_count
    || (
      targetEnvironment === "staging"
      && database.candidate_migration_count
        !== database.source_migration_count
    )
    || !/^[a-f0-9]{64}$/u.test(database?.inventory_sha256 ?? "")
    || !exactKeys(counts, [
      "columns",
      "functions",
      "policies",
      "relations",
      "sequences",
      "triggers",
      "types",
      "views",
    ])
    || Object.values(counts).some(
      (count) => !Number.isSafeInteger(count) || count < 0,
    )
    || database.owner_acl_rls_exact !== true
    || database.schema_definition_exact !== true
    || database.data_content_hmac_exact !== true
    || database.role_contract_exact !== true
    || !exactKeys(identity, [
      "admin_count",
      "auth_user_count",
      "hmac_exact",
      "staff_count",
    ])
    || identity?.hmac_exact !== true
    || !Number.isSafeInteger(identity?.auth_user_count)
    || !Number.isSafeInteger(identity?.staff_count)
    || !Number.isSafeInteger(identity?.admin_count)
    || identity.admin_count > identity.staff_count
    || !exactKeys(security, [
      "source_adaptive_rls",
      "unauthorized_access_denied",
      "unauthorized_member_rows",
      "underlying_member_rows",
    ])
    || security?.source_adaptive_rls !== true
    || !Number.isSafeInteger(security?.underlying_member_rows)
    || security.unauthorized_member_rows !== 0
    || typeof security.unauthorized_access_denied !== "boolean"
    || !exactKeys(isolation, [
      "plaintext_dump_uploaded",
      "provider_configuration",
      "published_ports",
      "raw_inventory_uploaded",
      "source_and_dump_same_exported_snapshot",
      "target_network",
    ])
    || isolation?.source_and_dump_same_exported_snapshot !== true
    || isolation?.target_network !== "none"
    || isolation?.published_ports !== 0
    || isolation?.provider_configuration !== false
    || isolation?.plaintext_dump_uploaded !== false
    || isolation?.raw_inventory_uploaded !== false
    || (
      targetEnvironment === "staging"
        ? value.encrypted_backup !== null
        : (
            !exactKeys(value.encrypted_backup, [
              "algorithm",
              "sha256",
            ])
            || value.encrypted_backup?.algorithm !== "AES256"
            || !/^[a-f0-9]{64}$/u.test(
              value.encrypted_backup?.sha256 ?? "",
            )
          )
    )
  ) {
    throw new Error("Restorebewijs is niet canoniek of releasegebonden");
  }
  return value;
}

async function main() {
  const inputPath = required(process.env, "RESTORE_VERIFICATION_PATH");
  const outputPath = required(process.env, "RESTORE_EVIDENCE_PATH");
  const raw = JSON.parse(await readFile(inputPath, "utf8"));
  const evidence = buildRestoreEvidence(raw, process.env);
  await writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, {
    mode: 0o600,
  });
  process.stdout.write("Geredigeerd restorebewijs is aangemaakt.\n");
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Restorebewijs kon niet worden gemaakt"}\n`,
    );
    process.exitCode = 1;
  });
}
