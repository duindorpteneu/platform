import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const CONSTRAINT_KEYS = new Set([
  "check",
  "exclusion",
  "foreign_key",
  "other",
  "primary_key",
  "unique",
]);
const SECURITY_KEYS = [
  "authenticated_app_usage",
  "authenticated_staff_rpc_execute",
  "service_role_session_rpc_execute",
  "service_role_staff_rpc_denied",
  "underlying_member_rows",
  "unauthorized_access_denied",
  "unauthorized_member_rows",
];
const TOP_LEVEL_KEYS = [
  "constraints",
  "entity_counts",
  "invalid_constraints",
  "migration_versions",
  "postgres_major",
  "rls_enabled_tables",
  "security_contract",
];

function exactKeys(value, expected) {
  return value
    && typeof value === "object"
    && !Array.isArray(value)
    && Object.keys(value).sort().join(",") === [...expected].sort().join(",");
}

function nonNegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

export async function expectedRestoreContract(repositoryRoot) {
  const migrationNames = await readdir(
    path.join(repositoryRoot, "supabase/migrations"),
  );
  const migrationVersions = migrationNames
    .filter((name) => /^\d{14}_.+\.sql$/u.test(name))
    .map((name) => name.slice(0, 14))
    .sort();
  const cleanupContract = await readFile(
    path.join(
      repositoryRoot,
      "scripts/staging/sql/operational-cleanup-contract.sql",
    ),
    "utf8",
  );
  const entityKeys = [...new Set(
    [...cleanupContract.matchAll(
      /'(app|private)\.([a-z][a-z0-9_]*)'/gu,
    )].map((match) => `${match[1]}.${match[2]}`),
  )].sort();
  if (
    migrationVersions.length === 0
    || entityKeys.length === 0
  ) {
    throw new Error("Repository restorecontract is onvolledig");
  }
  return { entityKeys, migrationVersions };
}

export function validateRestoreVerification(raw, expected) {
  if (
    !exactKeys(raw, TOP_LEVEL_KEYS)
    || raw.postgres_major !== 17
    || raw.invalid_constraints !== 0
    || !Number.isSafeInteger(raw.rls_enabled_tables)
    || raw.rls_enabled_tables < 1
    || !Array.isArray(raw.migration_versions)
    || raw.migration_versions.join(",")
      !== expected.migrationVersions.join(",")
    || !exactKeys(raw.security_contract, SECURITY_KEYS)
    || raw.security_contract.authenticated_app_usage !== true
    || raw.security_contract.authenticated_staff_rpc_execute !== true
    || raw.security_contract.service_role_session_rpc_execute !== true
    || raw.security_contract.service_role_staff_rpc_denied !== true
    || !Number.isSafeInteger(
      raw.security_contract.underlying_member_rows,
    )
    || raw.security_contract.underlying_member_rows < 1
    || raw.security_contract.unauthorized_access_denied !== true
    || raw.security_contract.unauthorized_member_rows !== 0
    || !raw.constraints
    || typeof raw.constraints !== "object"
    || Array.isArray(raw.constraints)
    || Object.keys(raw.constraints).some((key) =>
      !CONSTRAINT_KEYS.has(key)
      || !nonNegativeInteger(raw.constraints[key]))
    || Object.values(raw.constraints)
      .reduce((sum, value) => sum + value, 0) < 1
    || !raw.entity_counts
    || typeof raw.entity_counts !== "object"
    || Array.isArray(raw.entity_counts)
    || Object.keys(raw.entity_counts).sort().join(",")
      !== expected.entityKeys.join(",")
    || Object.values(raw.entity_counts).some((value) =>
      !nonNegativeInteger(value))
  ) {
    throw new Error("Restoreverificatie wijkt af van het volledige contract");
  }
  return true;
}

async function main() {
  const [verificationPath] = process.argv.slice(2);
  if (!verificationPath) {
    throw new Error(
      "Gebruik validate-restore-verification.mjs <verification.json>",
    );
  }
  const repositoryRoot = process.cwd();
  validateRestoreVerification(
    JSON.parse(await readFile(verificationPath, "utf8")),
    await expectedRestoreContract(repositoryRoot),
  );
  process.stdout.write("Volledig migration/schema/ACL/RLS-restorecontract is bewezen.\n");
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Restoreverificatie is ongeldig"}\n`,
    );
    process.exitCode = 1;
  });
}
