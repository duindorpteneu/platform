import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const BLOCKER_KEYS = [
  "active_import_leases",
  "active_scan_grants",
  "database_email_enabled",
  "database_mollie_enabled",
  "inflight_email_jobs",
  "open_provider_payments",
];
const PRESERVED_KEYS = [
  "active_admins",
  "auth_users",
  "mail_templates",
  "seasons",
  "staff_profiles",
  "supplier_principals",
];
const CLEANUP_TABLE_COUNT = 105;
const PRESERVED_TABLE_COUNT = 28;

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

function integer(value, name) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${name} is ongeldig`);
  return parsed;
}

function exactIntegerObject(value, expectedKeys, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} is ongeldig`);
  const actualKeys = Object.keys(value).sort();
  const sortedExpected = [...expectedKeys].sort();
  if (actualKeys.length !== sortedExpected.length
    || actualKeys.some((key, index) => key !== sortedExpected[index])) {
    throw new Error(`${name} bevat onverwachte sleutels`);
  }
  return Object.fromEntries(actualKeys.map((key) => [key, integer(value[key], `${name}.${key}`)]));
}

function rowCounts(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("row_counts is ongeldig");
  const entries = Object.entries(value).sort(([left], [right]) => left.localeCompare(right));
  if (entries.length !== CLEANUP_TABLE_COUNT) {
    throw new Error(
      `row_counts bevat niet exact ${CLEANUP_TABLE_COUNT} cleanup-tabellen`,
    );
  }
  for (const [key, count] of entries) {
    if (!/^(app|private)\.[a-z][a-z0-9_]*$/u.test(key)) throw new Error("row_counts bevat een onveilige tabelsleutel");
    integer(count, `row_counts.${key}`);
  }
  return Object.fromEntries(entries.map(([key, count]) => [key, Number(count)]));
}

function timestamp(value, name) {
  const parsed = new Date(required({ [name]: value }, name));
  if (Number.isNaN(parsed.valueOf())) throw new Error(`${name} is ongeldig`);
  return parsed.toISOString();
}

export function buildCleanupEvidence(preflight, postcondition, values) {
  const mode = required(values, "CLEANUP_MODE");
  const releaseSha = required(values, "RELEASE_SHA");
  const projectRef = required(values, "SUPABASE_PROJECT_REF");
  if (!["dry-run", "apply"].includes(mode)) throw new Error("CLEANUP_MODE is ongeldig");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA is ongeldig");
  if (!/^[a-z0-9]{20}$/u.test(projectRef)) throw new Error("SUPABASE_PROJECT_REF is ongeldig");
  if (!preflight || preflight.schema_version !== 1 || preflight.mode !== "dry-run") {
    throw new Error("Cleanup-preflight is ongeldig");
  }
  if (!/^[a-f0-9]{64}$/u.test(preflight.state_digest ?? "")) {
    throw new Error("Cleanup-preflight mist een geldige intern gebruikte digest");
  }
  if (!/^\d{14}$/u.test(preflight.latest_migration_version ?? "")) {
    throw new Error("Cleanup-preflight mist een geldige migratieversie");
  }
  if (
    integer(preflight.cleanup_table_count, "cleanup_table_count")
      !== CLEANUP_TABLE_COUNT
    || integer(preflight.preserved_table_count, "preserved_table_count")
      !== PRESERVED_TABLE_COUNT
  ) {
    throw new Error("Cleanup-tablecontract is onverwacht");
  }

  const counts = rowCounts(preflight.row_counts);
  const blockers = exactIntegerObject(preflight.blockers, BLOCKER_KEYS, "blockers");
  const preservedBefore = exactIntegerObject(preflight.preserved, PRESERVED_KEYS, "preserved");
  const totalRows = integer(preflight.total_rows, "total_rows");
  if (Object.values(counts).reduce((sum, count) => sum + count, 0) !== totalRows) {
    throw new Error("Cleanup-totaal komt niet overeen met de tabeltellingen");
  }

  const evidence = {
    schema_version: 2,
    result: mode === "apply" ? "committed" : "dry-run",
    target: "duindorpteneu-staging-domain-cleanup",
    release_sha: releaseSha,
    source_project_fingerprint: createHash("sha256").update(projectRef).digest("hex").slice(0, 16),
    started_at: timestamp(values.STARTED_AT, "STARTED_AT"),
    completed_at: timestamp(values.COMPLETED_AT, "COMPLETED_AT"),
    preflight: {
      cleanup_table_count: CLEANUP_TABLE_COUNT,
      preserved_table_count: PRESERVED_TABLE_COUNT,
      latest_migration_version: preflight.latest_migration_version,
      total_rows: totalRows,
      non_empty_tables: integer(preflight.non_empty_tables, "non_empty_tables"),
      row_counts: counts,
      blockers,
      preserved: preservedBefore,
    },
    mutation: null,
    backup: null,
    exact_restore: null,
    runtime_recovery: null,
  };

  if (mode === "dry-run") {
    if (postcondition !== null) throw new Error("Dry-run mag geen postcondition bevatten");
    return evidence;
  }

  if (Object.values(blockers).some((count) => count !== 0)) {
    throw new Error("Apply-bewijs bevat een actieve veiligheidsblocker");
  }
  if (!postcondition || postcondition.schema_version !== 1 || postcondition.result !== "committed") {
    throw new Error("Cleanup-postcondition is ongeldig");
  }
  const runId = required(values, "CLEANUP_RUN_ID");
  if (!/^[a-f0-9-]{36}$/u.test(runId) || postcondition.cleanup_run_id !== runId) {
    throw new Error("Cleanup-runidentiteit komt niet overeen");
  }
  if (
    integer(postcondition.cleanup_table_count, "post.cleanup_table_count")
      !== CLEANUP_TABLE_COUNT
    || integer(postcondition.removed_rows, "post.removed_rows") !== totalRows
    || integer(postcondition.remaining_operational_rows, "post.remaining_operational_rows") !== 0
    || integer(postcondition.cleanup_audit_rows, "post.cleanup_audit_rows") !== 1) {
    throw new Error("Cleanup-postcondities zijn niet groen");
  }
  const preservedAfter = exactIntegerObject(postcondition.preserved, PRESERVED_KEYS, "post.preserved");
  if (JSON.stringify(preservedAfter) !== JSON.stringify(preservedBefore)) {
    throw new Error("Preserved tellingen zijn gewijzigd");
  }

  const backupChecksum = required(values, "BACKUP_CHECKSUM");
  const backupArtifact = required(values, "BACKUP_ARTIFACT_NAME");
  const backupArtifactId = required(values, "BACKUP_ARTIFACT_ID");
  if (!/^[a-f0-9]{64}$/u.test(backupChecksum)
    || !/^staging-domain-backup-[a-f0-9-]+$/u.test(backupArtifact)
    || !/^[1-9][0-9]*$/u.test(backupArtifactId)) {
    throw new Error("Backupbewijs is ongeldig");
  }

  evidence.mutation = {
    cleanup_run_id: runId,
    removed_rows: totalRows,
    remaining_operational_rows: 0,
    cleanup_audit_rows: 1,
    preserved: preservedAfter,
  };
  evidence.backup = {
    artifact_name: backupArtifact,
    artifact_id: backupArtifactId,
    encrypted_sha256: backupChecksum,
    encrypted: true,
    decrypted_restore_verified: true,
    restore_network: "none",
    retention_days: 30,
  };
  const runtimeRecoveryProven =
    required(values, "RUNTIME_RECOVERY_PROVEN");
  const exactRestoreProven =
    required(values, "EXACT_RESTORE_PROVEN");
  if (!["true", "false"].includes(runtimeRecoveryProven)) {
    throw new Error("Runtimeherstelbewijs is ongeldig");
  }
  if (exactRestoreProven !== "true") {
    throw new Error("Exact bron-/restorebewijs ontbreekt");
  }
  const recovered = runtimeRecoveryProven === "true";
  evidence.result = recovered ? "passed" : "committed";
  evidence.exact_restore = {
    data_hmac_exact: true,
    identity_hmac_exact: true,
    inventory_proven: true,
    owner_acl_rls_exact: true,
    role_contract_exact: true,
    schema_definition_exact: true,
  };
  evidence.runtime_recovery = {
    app_health_proven: recovered,
    scheduler_health_proven: recovered,
  };
  return evidence;
}

async function main() {
  const preflight = JSON.parse(await readFile(required(process.env, "CLEANUP_PREFLIGHT_PATH"), "utf8"));
  const postPath = process.env.CLEANUP_POSTCONDITION_PATH?.trim();
  const postcondition = postPath ? JSON.parse(await readFile(postPath, "utf8")) : null;
  const evidence = buildCleanupEvidence(preflight, postcondition, process.env);
  await writeFile(
    required(process.env, "CLEANUP_EVIDENCE_PATH"),
    `${JSON.stringify(evidence, null, 2)}\n`,
    { mode: 0o600 },
  );
  process.stdout.write("Geredigeerd staging-cleanupbewijs is aangemaakt.\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Cleanupbewijs kon niet worden gemaakt"}\n`);
    process.exitCode = 1;
  });
}
