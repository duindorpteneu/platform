import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const acceptedTlsModes = new Set(["require", "verify-ca", "verify-full"]);
const acceptedQueryParameters = new Set(["connect_timeout", "sslmode"]);

function required(value, name) {
  const normalized = value?.trim();
  if (!normalized) throw new Error(`${name} ontbreekt`);
  return normalized;
}

export function requireExplicitDatabaseTls(value) {
  const raw = required(value, "SUPABASE_DB_URL");
  if (/[\r\n]/u.test(raw)) {
    throw new Error("SUPABASE_DB_URL bevat ongeldige regeleinden");
  }

  let databaseUrl;
  try {
    databaseUrl = new URL(raw);
  } catch {
    throw new Error("SUPABASE_DB_URL is geen geldige URL");
  }

  if (!["postgres:", "postgresql:"].includes(databaseUrl.protocol)) {
    throw new Error("SUPABASE_DB_URL gebruikt geen PostgreSQL-protocol");
  }
  const hostnameLabels = databaseUrl.hostname.split(".");
  if (hostnameLabels.length < 2 || hostnameLabels.some(
    (label) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(label),
  )) {
    throw new Error("SUPABASE_DB_URL bevat geen enkele geldige DNS-host");
  }

  const queryParameters = [...new Set(databaseUrl.searchParams.keys())];
  const forbiddenParameters = queryParameters.filter(
    (parameter) => !acceptedQueryParameters.has(parameter),
  );
  if (forbiddenParameters.length > 0) {
    throw new Error("SUPABASE_DB_URL bevat een niet-toegestane databaseparameter");
  }
  for (const parameter of queryParameters) {
    if (databaseUrl.searchParams.getAll(parameter).length > 1) {
      throw new Error("SUPABASE_DB_URL bevat een dubbele databaseparameter");
    }
  }

  const connectTimeout = databaseUrl.searchParams.get("connect_timeout");
  if (connectTimeout !== null
    && (!/^[1-9][0-9]{0,2}$/u.test(connectTimeout) || Number(connectTimeout) > 120)) {
    throw new Error("SUPABASE_DB_URL bevat een ongeldige connectietimeout");
  }

  const tlsModes = databaseUrl.searchParams.getAll("sslmode");
  if (tlsModes.length === 1 && !acceptedTlsModes.has(tlsModes[0])) {
    throw new Error("SUPABASE_DB_URL bevat geen afdwingende TLS-modus");
  }
  if (tlsModes.length === 0) {
    databaseUrl.searchParams.set("sslmode", "require");
  }

  return databaseUrl.href;
}

async function main() {
  const githubEnvironmentPath = required(process.env.GITHUB_ENV, "GITHUB_ENV");
  const databaseUrl = requireExplicitDatabaseTls(process.env.SUPABASE_DB_URL);

  // Register the derived URL before later tools can mention it. The value itself
  // is only persisted through GitHub's environment file and is never printed.
  process.stdout.write(`::add-mask::${databaseUrl}\n`);
  await appendFile(
    githubEnvironmentPath,
    `SUPABASE_DB_URL=${databaseUrl}\n`,
    { encoding: "utf8" },
  );
  process.stdout.write("Databaseverbinding is op expliciete TLS vastgezet.\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Database-TLS kon niet worden afgedwongen"}\n`);
    process.exitCode = 1;
  });
}
