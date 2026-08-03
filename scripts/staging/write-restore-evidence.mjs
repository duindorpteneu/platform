import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const ENTITY_KEYS = [
  "app.seasons",
  "app.staff_profiles",
  "app.import_batches",
  "app.members",
  "app.member_seasons",
  "app.articles",
  "app.article_variants",
  "app.member_orders",
  "app.order_lines",
  "app.order_package_snapshots",
  "app.order_package_snapshot_items",
  "app.payments",
  "app.delivery_receipts",
  "app.inventory_reservations",
  "app.inventory_allocations",
  "app.inventory_allocation_events",
  "app.inventory_movements",
  "app.fulfilments",
  "app.fulfilment_lines",
  "app.audit_logs",
  "private.parent_accounts",
  "private.parent_sessions",
  "private.email_jobs",
  "private.payment_events",
  "private.qr_tokens",
  "private.qr_order_identities",
  "private.qr_order_locators",
  "private.qr_scan_grants",
  "private.fulfilment_notification_events",
];
const CONSTRAINT_KEYS = new Set(["check", "foreign_key", "primary_key", "unique", "exclusion", "other"]);

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

function integer(value, name) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${name} is geen geldig geheel getal`);
  return parsed;
}

function isoTimestamp(value, name) {
  const date = new Date(required({ [name]: value }, name));
  if (Number.isNaN(date.valueOf())) throw new Error(`${name} is geen geldige tijd`);
  return date.toISOString();
}

function validatedCounts(value, keys, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} is ongeldig`);
  const actualKeys = Object.keys(value).sort();
  const expectedKeys = [...keys].sort();
  if (actualKeys.length !== expectedKeys.length || actualKeys.some((key, index) => key !== expectedKeys[index])) {
    throw new Error(`${name} bevat onverwachte sleutels`);
  }
  return Object.fromEntries(actualKeys.map((key) => [key, integer(value[key], `${name}.${key}`)]));
}

export function buildRestoreEvidence(raw, values) {
  const releaseSha = required(values, "RELEASE_SHA");
  const projectRef = required(values, "SUPABASE_PROJECT_REF");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA is ongeldig");
  if (!/^[a-z0-9]{20}$/u.test(projectRef)) throw new Error("SUPABASE_PROJECT_REF is ongeldig");
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("Restoreverificatie is ongeldig");
  if (raw.postgres_major !== 17) throw new Error("Restore draaide niet op PostgreSQL 17");
  if (raw.invalid_constraints !== 0) throw new Error("Restore bevat ongeldige constraints");

  const migrationVersions = raw.migration_versions;
  if (!Array.isArray(migrationVersions) || migrationVersions.length === 0
    || migrationVersions.some((version) => !/^\d{14}$/u.test(String(version)))) {
    throw new Error("Migratieversies zijn ongeldig");
  }
  const constraints = raw.constraints && typeof raw.constraints === "object" && !Array.isArray(raw.constraints)
    ? Object.fromEntries(Object.entries(raw.constraints).map(([key, value]) => {
      if (!CONSTRAINT_KEYS.has(key)) throw new Error("Constraintbewijs bevat een onverwacht type");
      return [key, integer(value, `constraints.${key}`)];
    }))
    : (() => { throw new Error("Constraintbewijs is ongeldig"); })();
  if (Object.values(constraints).reduce((sum, value) => sum + value, 0) === 0) {
    throw new Error("Constraintbewijs is leeg");
  }

  const entityCounts = validatedCounts(raw.entity_counts, ENTITY_KEYS, "entity_counts");
  const rpoSeconds = integer(values.RPO_SECONDS, "RPO_SECONDS");
  const rtoSeconds = integer(values.RTO_SECONDS, "RTO_SECONDS");
  const rpoTargetSeconds = 24 * 60 * 60;
  const rtoTargetSeconds = 4 * 60 * 60;
  if (rpoSeconds > rpoTargetSeconds) throw new Error("De restore-oefening overschrijdt de RPO van 24 uur");
  if (rtoSeconds > rtoTargetSeconds) throw new Error("De restore-oefening overschrijdt de RTO van 4 uur");

  return {
    schema_version: 1,
    result: "passed",
    target: "staging-logical-backup-isolated-restore",
    release_sha: releaseSha,
    source_project_fingerprint: createHash("sha256").update(projectRef).digest("hex").slice(0, 16),
    started_at: isoTimestamp(values.STARTED_AT, "STARTED_AT"),
    backup_snapshot_at: isoTimestamp(values.BACKUP_SNAPSHOT_AT, "BACKUP_SNAPSHOT_AT"),
    completed_at: isoTimestamp(values.COMPLETED_AT, "COMPLETED_AT"),
    objectives: {
      rpo_seconds: rpoSeconds,
      rpo_target_seconds: rpoTargetSeconds,
      rto_seconds: rtoSeconds,
      rto_target_seconds: rtoTargetSeconds,
    },
    database: {
      postgres_major: 17,
      migration_versions: migrationVersions.map(String),
      constraints,
      invalid_constraints: 0,
      rls_enabled_tables: integer(raw.rls_enabled_tables, "rls_enabled_tables"),
      aggregate_entity_counts: entityCounts,
    },
    isolation: {
      target_network: "none",
      published_ports: 0,
      provider_configuration: false,
      dump_uploaded: false,
    },
  };
}

async function main() {
  const inputPath = required(process.env, "RESTORE_VERIFICATION_PATH");
  const outputPath = required(process.env, "RESTORE_EVIDENCE_PATH");
  const raw = JSON.parse(await readFile(inputPath, "utf8"));
  const evidence = buildRestoreEvidence(raw, process.env);
  await writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  process.stdout.write("Geredigeerd restorebewijs is aangemaakt.\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Restorebewijs kon niet worden gemaakt"}\n`);
    process.exitCode = 1;
  });
}
