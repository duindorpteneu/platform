import { createHash } from "node:crypto";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const TOP_LEVEL_KEYS = [
  "columns",
  "constraints",
  "contractVersion",
  "defaultAcls",
  "functions",
  "identities",
  "indexes",
  "migrations",
  "policies",
  "postgresMajor",
  "relations",
  "roles",
  "schemas",
  "security",
  "sequences",
  "triggers",
  "types",
  "views",
];

function exactKeys(value, keys) {
  return value
    && typeof value === "object"
    && !Array.isArray(value)
    && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, canonical(child)]),
    );
  }
  return value;
}

function sha256(value) {
  return createHash("sha256")
    .update(JSON.stringify(canonical(value)))
    .digest("hex");
}

function sectionDifference(name, source, restored) {
  if (!Array.isArray(source) || !Array.isArray(restored)) return name;
  const keyFor = (item) => item?.identity ?? item?.name
    ?? JSON.stringify(canonical(item));
  const sourceByKey = new Map(source.map((item) => [keyFor(item), item]));
  const restoredByKey = new Map(
    restored.map((item) => [keyFor(item), item]),
  );
  const missing = [...sourceByKey.keys()]
    .filter((key) => !restoredByKey.has(key));
  const added = [...restoredByKey.keys()]
    .filter((key) => !sourceByKey.has(key));
  const changed = [...sourceByKey.keys()].filter((key) =>
    restoredByKey.has(key)
    && sha256(sourceByKey.get(key)) !== sha256(restoredByKey.get(key)));
  const sample = (values) => values.slice(0, 4).join("|") || "-";
  const changedFields = changed.slice(0, 4).map((key) => {
    const sourceItem = sourceByKey.get(key);
    const restoredItem = restoredByKey.get(key);
    const fields = [...new Set([
      ...Object.keys(sourceItem ?? {}),
      ...Object.keys(restoredItem ?? {}),
    ])].filter((field) =>
      sha256(sourceItem?.[field]) !== sha256(restoredItem?.[field]));
    return `${key}:${fields.join("+")}`;
  });
  return `${name}[missing=${missing.length}:${sample(missing)};`
    + `added=${added.length}:${sample(added)};`
    + `changed=${changed.length}:${sample(changedFields)}]`;
}

function safeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function validateInventory(value) {
  if (
    !exactKeys(value, TOP_LEVEL_KEYS)
    || value.contractVersion !== 2
    || value.postgresMajor !== 17
    || !Array.isArray(value.migrations)
    || value.migrations.some((item) => !/^\d{14}$/u.test(item))
    || !Array.isArray(value.schemas)
    || !Array.isArray(value.relations)
    || !Array.isArray(value.columns)
    || !Array.isArray(value.types)
    || !Array.isArray(value.views)
    || !Array.isArray(value.sequences)
    || !Array.isArray(value.constraints)
    || !Array.isArray(value.indexes)
    || !Array.isArray(value.policies)
    || !Array.isArray(value.functions)
    || !Array.isArray(value.triggers)
    || !Array.isArray(value.defaultAcls)
    || !Array.isArray(value.roles)
    || !exactKeys(value.identities, [
      "adminCount",
      "authUserCount",
      "authUserIdHmac",
      "staffCount",
      "staffIdHmac",
    ])
    || !safeInteger(value.identities.authUserCount)
    || !safeInteger(value.identities.staffCount)
    || !safeInteger(value.identities.adminCount)
    || value.identities.adminCount > value.identities.staffCount
    || !/^[a-f0-9]{64}$/u.test(value.identities.authUserIdHmac)
    || !/^[a-f0-9]{64}$/u.test(value.identities.staffIdHmac)
    || !exactKeys(value.security, [
      "unauthorizedAccessDenied",
      "underlyingMemberRows",
      "unauthorizedMemberRows",
    ])
    || !safeInteger(value.security.underlyingMemberRows)
    || value.security.unauthorizedMemberRows !== 0
    || value.security.unauthorizedAccessDenied !== true
    || value.relations.some((relation) =>
      typeof relation?.identity !== "string"
      || !["r", "p", "v", "m", "S"].includes(relation.kind)
      || (
        ["r", "p"].includes(relation.kind)
        && (
          !safeInteger(relation.rowCount)
          || !/^[a-f0-9]{64}$/u.test(relation.rowHmac)
        )
      )
      || (
        !["r", "p"].includes(relation.kind)
        && (relation.rowCount !== null || relation.rowHmac !== null)
      ))
    || !value.relations.some((relation) =>
      relation.identity === "app.members"
      && relation.kind === "r"
      && relation.rls === true)
    || value.columns.some((column) =>
      typeof column?.identity !== "string"
      || !Number.isSafeInteger(column.position)
      || column.position < 1
      || typeof column.type !== "string")
    || value.types.some((type) =>
      typeof type?.identity !== "string"
      || !Array.isArray(type.enumLabels))
    || value.views.some((view) =>
      typeof view?.identity !== "string"
      || !/^[a-f0-9]{64}$/u.test(view.definitionSha256))
    || value.sequences.some((sequence) =>
      typeof sequence?.identity !== "string"
      || !Number.isSafeInteger(sequence.lastValue)
      || typeof sequence.isCalled !== "boolean")
    || value.functions.some((procedure) =>
      typeof procedure?.identity !== "string"
      || !/^[a-f0-9]{64}$/u.test(procedure.definitionSha256))
    || value.roles.length !== 12
    || value.roles.some((role) =>
      typeof role?.name !== "string"
      || typeof role.superuser !== "boolean"
      || typeof role.bypassRls !== "boolean"
      || !Array.isArray(role.memberships))
  ) {
    throw new Error("Source/restore-inventory heeft een ongeldig contract");
  }
  return value;
}

async function repositoryMigrations(repositoryRoot) {
  return (await readdir(path.join(repositoryRoot, "supabase/migrations")))
    .filter((name) => /^\d{14}_.+\.sql$/u.test(name))
    .map((name) => name.slice(0, 14))
    .sort();
}

export async function validateSourceRestoreInventory({
  source,
  restored,
  mode,
  repositoryRoot,
}) {
  validateInventory(source);
  validateInventory(restored);
  if (!["current", "source"].includes(mode)) {
    throw new Error("Onbekende restorecontractmodus");
  }
  const expectedMigrations = await repositoryMigrations(repositoryRoot);
  const sourceMigrations = source.migrations;
  if (
    sourceMigrations.length === 0
    || sourceMigrations.length > expectedMigrations.length
    || sourceMigrations.some((version, index) =>
      version !== expectedMigrations[index])
    || (
      mode === "current"
      && sourceMigrations.length !== expectedMigrations.length
    )
  ) {
    throw new Error("Bronmigraties zijn geen geldige kandidaatprefix");
  }
  const sourceDigest = sha256(source);
  const restoredDigest = sha256(restored);
  if (sourceDigest !== restoredDigest) {
    const mismatchedSections = TOP_LEVEL_KEYS.filter((key) =>
      sha256(source[key]) !== sha256(restored[key]));
    throw new Error(
      "Herstelde database wijkt af van de bronsnapshot: "
      + mismatchedSections.map((key) =>
        sectionDifference(key, source[key], restored[key])).join(","),
    );
  }
  return {
    contract_version: 2,
    result: "passed",
    contract_mode: mode,
    inventory_sha256: sourceDigest,
    postgres_major: 17,
    source_migration_count: sourceMigrations.length,
    candidate_migration_count: expectedMigrations.length,
    relation_count: source.relations.length,
    column_count: source.columns.length,
    type_count: source.types.length,
    view_count: source.views.length,
    sequence_count: source.sequences.length,
    function_count: source.functions.length,
    policy_count: source.policies.length,
    trigger_count: source.triggers.length,
    underlying_member_rows: source.security.underlyingMemberRows,
    unauthorized_member_rows: 0,
    unauthorized_member_access_denied:
      source.security.unauthorizedAccessDenied,
    auth_user_count: source.identities.authUserCount,
    staff_count: source.identities.staffCount,
    admin_count: source.identities.adminCount,
    owner_acl_rls_exact: true,
    schema_definition_exact: true,
    data_hmac_exact: true,
    role_contract_exact: true,
    identity_hmac_exact: true,
  };
}

async function main() {
  const [sourcePath, restoredPath, mode, outputPath] =
    process.argv.slice(2);
  if (!sourcePath || !restoredPath || !mode || !outputPath) {
    throw new Error(
      "Gebruik validate-source-restore-inventory.mjs "
      + "<source.json> <restore.json> <current|source> <bewijs.json>",
    );
  }
  const result = await validateSourceRestoreInventory({
    source: JSON.parse(await readFile(sourcePath, "utf8")),
    restored: JSON.parse(await readFile(restoredPath, "utf8")),
    mode,
    repositoryRoot: process.cwd(),
  });
  await writeFile(outputPath, `${JSON.stringify(result)}\n`, {
    mode: 0o600,
  });
  process.stdout.write(
    "Bronsnapshot en geïsoleerde restore zijn exact gelijk.\n",
  );
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Restorevergelijking faalde"}\n`,
    );
    process.exitCode = 1;
  });
}
