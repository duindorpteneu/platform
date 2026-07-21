import { pathToFileURL } from "node:url";

export const STAGING_ORIGIN = "https://staging-duindorp.dgwebservices.nl";
export const RESTORE_CONFIRMATION = "STAGING-RESTORE";

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

export function validateStagingRestoreTarget(values) {
  const environment = required(values, "TARGET_ENVIRONMENT");
  const appUrl = required(values, "STAGING_APP_URL");
  const projectRef = required(values, "SUPABASE_PROJECT_REF");
  const databaseUrl = required(values, "SUPABASE_DB_URL");
  const releaseSha = required(values, "RELEASE_SHA");
  const confirmation = required(values, "CONFIRM_TARGET");

  if (environment !== "staging") throw new Error("Alleen de stagingomgeving is toegestaan");
  if (confirmation !== RESTORE_CONFIRMATION) throw new Error("De stagingbevestiging is ongeldig");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA moet een volledige commit-SHA zijn");
  if (!/^[a-z0-9]{20}$/u.test(projectRef)) throw new Error("SUPABASE_PROJECT_REF heeft een ongeldig formaat");

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

  const directHost = `db.${projectRef}.supabase.co`;
  const isDirect = parsedDatabaseUrl.hostname === directHost;
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

function isMainModule() {
  return process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMainModule()) {
  try {
    validateStagingRestoreTarget(process.env);
    process.stdout.write("Staging restore-doel en release-identiteit zijn geldig.\n");
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "Stagingdoel is ongeldig"}\n`);
    process.exitCode = 1;
  }
}
