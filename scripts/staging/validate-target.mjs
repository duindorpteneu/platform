import { pathToFileURL } from "node:url";

export const STAGING_ORIGIN = "https://staging-duindorp.dgwebservices.nl";
export const STAGING_PROJECT_REF = "dxbdjtbyghsovlrdcwcr";
export const PRODUCTION_PROJECT_REF = "wobcbufmmputydtzemyu";
export const RESTORE_CONFIRMATION = "STAGING-RESTORE";
export const CLEANUP_DRY_RUN_CONFIRMATION = "STAGING-CLEANUP-DRY-RUN";
export const CLEANUP_APPLY_CONFIRMATION = "STAGING-CLEANUP-APPLY";

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

function validateStagingTarget(values, confirmationContract, requireExactProject) {
  const environment = required(values, "TARGET_ENVIRONMENT");
  const appUrl = required(values, "STAGING_APP_URL");
  const projectRef = required(values, "SUPABASE_PROJECT_REF");
  const databaseUrl = required(values, "SUPABASE_DB_URL");
  const releaseSha = required(values, "RELEASE_SHA");
  const confirmation = required(values, "CONFIRM_TARGET");

  if (environment !== "staging") throw new Error("Alleen de stagingomgeving is toegestaan");
  if (confirmation !== confirmationContract) throw new Error("De stagingbevestiging is ongeldig");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA moet een volledige commit-SHA zijn");
  if (!/^[a-z0-9]{20}$/u.test(projectRef)) throw new Error("SUPABASE_PROJECT_REF heeft een ongeldig formaat");
  if (projectRef === PRODUCTION_PROJECT_REF) throw new Error("Het productionproject is nooit toegestaan");
  if (requireExactProject && projectRef !== STAGING_PROJECT_REF) {
    throw new Error("Het project is niet het vaste Duindorp-stagingproject");
  }

  let parsedAppUrl;
  let parsedDatabaseUrl;
  try {
    parsedAppUrl = new URL(appUrl);
    parsedDatabaseUrl = new URL(databaseUrl);
  } catch {
    throw new Error("Een doel-URL is ongeldig");
  }

  if (parsedAppUrl.origin !== STAGING_ORIGIN || parsedAppUrl.href !== `${STAGING_ORIGIN}/`) {
    throw new Error("De applicatie-URL is niet de vaste stagingorigin");
  }
  if (!["postgres:", "postgresql:"].includes(parsedDatabaseUrl.protocol)) {
    throw new Error("De database-URL gebruikt geen PostgreSQL-protocol");
  }
  if (!parsedDatabaseUrl.username || !parsedDatabaseUrl.password) {
    throw new Error("De database-URL mist credentials");
  }
  if (parsedDatabaseUrl.pathname !== "/postgres") {
    throw new Error("De database-URL wijst niet naar de stagingdatabase");
  }
  if (parsedDatabaseUrl.searchParams.get("sslmode") === "disable") {
    throw new Error("TLS mag niet zijn uitgeschakeld voor de stagingdatabase");
  }
  if (requireExactProject
    && !["require", "verify-ca", "verify-full"].includes(parsedDatabaseUrl.searchParams.get("sslmode"))) {
    throw new Error("Cleanup vereist een expliciete TLS-databasemodus");
  }

  const directHost = `db.${projectRef}.supabase.co`;
  const isDirect = parsedDatabaseUrl.hostname === directHost
    && decodeURIComponent(parsedDatabaseUrl.username) === "postgres";
  const isPooler = parsedDatabaseUrl.hostname.endsWith(".pooler.supabase.com")
    && decodeURIComponent(parsedDatabaseUrl.username) === `postgres.${projectRef}`;
  if (!isDirect && !isPooler) {
    throw new Error("De database-URL en stagingprojectref komen niet overeen");
  }
  if (/production|prod(?:uction)?[-_.]/iu.test(`${parsedDatabaseUrl.hostname} ${appUrl}`)) {
    throw new Error("Een productiondoel is niet toegestaan");
  }

  return Object.freeze({ environment, appUrl: STAGING_ORIGIN, projectRef, releaseSha });
}

export function validateStagingRestoreTarget(values) {
  return validateStagingTarget(values, RESTORE_CONFIRMATION, true);
}

export function validateStagingCleanupTarget(values) {
  const mode = required(values, "CLEANUP_MODE");
  if (!["dry-run", "apply"].includes(mode)) throw new Error("CLEANUP_MODE is ongeldig");
  const confirmation = mode === "apply"
    ? CLEANUP_APPLY_CONFIRMATION
    : CLEANUP_DRY_RUN_CONFIRMATION;
  return {
    ...validateStagingTarget(values, confirmation, true),
    mode,
  };
}

function isMainModule() {
  return process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMainModule()) {
  try {
    if (process.env.TARGET_OPERATION === "cleanup") {
      validateStagingCleanupTarget(process.env);
      process.stdout.write("Staging cleanup-doel, modus en release-identiteit zijn geldig.\n");
    } else {
      validateStagingRestoreTarget(process.env);
      process.stdout.write("Staging restore-doel en release-identiteit zijn geldig.\n");
    }
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "Stagingdoel is ongeldig"}\n`);
    process.exitCode = 1;
  }
}
