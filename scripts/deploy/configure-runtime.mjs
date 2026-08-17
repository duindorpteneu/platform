import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { createHash, createPublicKey } from "node:crypto";
import path from "node:path";

const environment = process.env.DEPLOY_ENVIRONMENT;
const releaseSha = process.env.RELEASE_SHA?.trim() ?? "";
const releaseArtifactDigest =
  process.env.RELEASE_ARTIFACT_DIGEST?.trim() ?? "";
const rules = {
  staging: {
    host: "duindorpsv.dgwebservices.nl",
    port: "14000",
    root: "/srv/apps/duindorpteneu/staging",
    project: "duindorpteneu-staging",
    supabaseRef: "dxbdjtbyghsovlrdcwcr",
  },
  production: {
    host: "duindorp.dgwebservices.nl",
    port: "24000",
    root: "/srv/apps/duindorpteneu/production",
    project: "duindorpteneu-production",
    supabaseRef: "wobcbufmmputydtzemyu",
  },
};
const errors = new Set();

function invalid(name) { errors.add(name); }
function required(name, minimum = 1) {
  const value = process.env[name]?.trim() ?? "";
  if (value.length < minimum || /[\0\r\n]/.test(value)) invalid(name);
  return value;
}
function optional(name) {
  const value = process.env[name]?.trim() ?? "";
  if (/[\0\r\n]/.test(value)) invalid(name);
  return value;
}
function jwt(name, expectedRole, expectedRef) {
  const value = required(name, 40);
  const parts = value.split(".");
  if (parts.length !== 3 || parts.some((part) => !/^[A-Za-z0-9_-]+$/.test(part))) return invalid(name);
  try {
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    if (payload.role !== expectedRole || payload.ref !== expectedRef || typeof payload.exp !== "number") invalid(name);
  } catch { invalid(name); }
}
function postgresUrl(name, projectRef) {
  const value = required(name, 20);
  try {
    const parsed = new URL(value);
    const direct = parsed.hostname === `db.${projectRef}.supabase.co` && parsed.username === "postgres";
    const pooler = parsed.hostname.endsWith(".pooler.supabase.com") && parsed.username === `postgres.${projectRef}`;
    const unsafeTls = parsed.searchParams.get("sslmode") === "disable";
    if (
      !["postgres:", "postgresql:"].includes(parsed.protocol)
      || (!direct && !pooler)
      || parsed.pathname !== "/postgres"
      || unsafeTls
    ) invalid(name);
  } catch { invalid(name); }
}
function canonicalBase64UrlSecret(name, value) {
  try {
    if (
      !/^[A-Za-z0-9_-]{43}$/.test(value)
      || Buffer.from(value, "base64url").length !== 32
      || Buffer.from(value, "base64url").toString("base64url") !== value
    ) invalid(name);
  } catch { invalid(name); }
}

if (!(environment in rules)) invalid("DEPLOY_ENVIRONMENT");
const expected = environment in rules ? rules[environment] : { host: "", port: "", root: "", project: "", supabaseRef: "" };
if (!/^[a-f0-9]{40}$/.test(releaseSha)) invalid("RELEASE_SHA");
if (!/^sha256:[a-f0-9]{64}$/.test(releaseArtifactDigest)) {
  invalid("RELEASE_ARTIFACT_DIGEST");
}

const appHost = required("APP_HOST");
const appPort = required("APP_BIND_PORT");
const appUrl = required("NEXT_PUBLIC_APP_URL");
const projectRef = required("SUPABASE_PROJECT_REF");
const supabaseUrl = required("NEXT_PUBLIC_SUPABASE_URL");
const supabaseJwks = required("SUPABASE_JWKS", 40);
if (appHost !== expected.host) invalid("APP_HOST");
if (appPort !== expected.port) invalid("APP_BIND_PORT");
if (process.env.RUNTIME_DIRECTORY !== expected.root) invalid("RUNTIME_DIRECTORY");
if (process.env.COMPOSE_PROJECT_NAME !== expected.project) invalid("COMPOSE_PROJECT_NAME");
if (!/^[a-z0-9]{20}$/.test(projectRef)) invalid("SUPABASE_PROJECT_REF");
if (projectRef !== expected.supabaseRef) invalid("SUPABASE_PROJECT_REF");
if (appUrl !== `https://${appHost}`) invalid("NEXT_PUBLIC_APP_URL");
if (supabaseUrl !== `https://${projectRef}.supabase.co`) invalid("NEXT_PUBLIC_SUPABASE_URL");
try {
  const parsed = JSON.parse(supabaseJwks);
  if (
    !parsed || Object.keys(parsed).some((key) => key !== "keys") || !Array.isArray(parsed.keys) || parsed.keys.length < 1
    || parsed.keys.some((key) => key?.kty !== "EC" || key?.crv !== "P-256" || key?.alg !== "ES256"
      || typeof key?.kid !== "string" || key.kid.length < 1
      || !/^[A-Za-z0-9_-]{40,}$/.test(key?.x ?? "") || !/^[A-Za-z0-9_-]{40,}$/.test(key?.y ?? ""))
  ) invalid("SUPABASE_JWKS");
} catch { invalid("SUPABASE_JWKS"); }

jwt("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon", projectRef);
jwt("SUPABASE_SERVICE_ROLE_KEY", "service_role", projectRef);
postgresUrl("SUPABASE_DB_URL", projectRef);
required("PARENT_TOKEN_PEPPER", 32);
const qrTokenPepper = required("QR_TOKEN_PEPPER", 43);
const qrTokenPepperVersion = required("QR_TOKEN_PEPPER_VERSION");
const previousQrTokenPepper = optional("QR_TOKEN_PREVIOUS_PEPPER");
const previousQrTokenPepperVersion = optional("QR_TOKEN_PREVIOUS_PEPPER_VERSION");
canonicalBase64UrlSecret("QR_TOKEN_PEPPER", qrTokenPepper);
if (!/^[1-9][0-9]{0,3}$/.test(qrTokenPepperVersion)) {
  invalid("QR_TOKEN_PEPPER_VERSION");
}
if (Boolean(previousQrTokenPepper) !== Boolean(previousQrTokenPepperVersion)) {
  invalid("QR_TOKEN_PREVIOUS_PEPPER");
  invalid("QR_TOKEN_PREVIOUS_PEPPER_VERSION");
}
if (previousQrTokenPepper) {
  canonicalBase64UrlSecret(
    "QR_TOKEN_PREVIOUS_PEPPER",
    previousQrTokenPepper,
  );
}
if (
  previousQrTokenPepperVersion
  && (
    !/^[1-9][0-9]{0,3}$/.test(previousQrTokenPepperVersion)
    || previousQrTokenPepperVersion === qrTokenPepperVersion
  )
) invalid("QR_TOKEN_PREVIOUS_PEPPER_VERSION");
required("CRON_SECRET", 16);
const dynamicImportEnabled = required("DYNAMIC_IMPORT_ENABLED");
const importStagingKey = optional("IMPORT_STAGING_ENCRYPTION_KEY");
const importRetentionHours = required("IMPORT_RAW_RETENTION_HOURS");
if (!["true", "false"].includes(dynamicImportEnabled)) invalid("DYNAMIC_IMPORT_ENABLED");
if (!/^(?:[1-9]|[1-6][0-9]|7[0-2])$/.test(importRetentionHours)) invalid("IMPORT_RAW_RETENTION_HOURS");
if (importStagingKey) {
  try {
    if (
      !/^[A-Za-z0-9_-]{43}$/.test(importStagingKey)
      || Buffer.from(importStagingKey, "base64url").length !== 32
      || Buffer.from(importStagingKey, "base64url").toString("base64url") !== importStagingKey
    ) invalid("IMPORT_STAGING_ENCRYPTION_KEY");
  } catch { invalid("IMPORT_STAGING_ENCRYPTION_KEY"); }
}
if (dynamicImportEnabled === "true" && !importStagingKey) invalid("IMPORT_STAGING_ENCRYPTION_KEY");
const operationsHeartbeatUrl = optional("OPERATIONS_HEARTBEAT_URL");
if (environment === "production" && !operationsHeartbeatUrl) invalid("OPERATIONS_HEARTBEAT_URL");
if (operationsHeartbeatUrl) {
  try {
    const parsed = new URL(operationsHeartbeatUrl);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) invalid("OPERATIONS_HEARTBEAT_URL");
  } catch { invalid("OPERATIONS_HEARTBEAT_URL"); }
}

const encryptionKey = required("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY", 40);
try {
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(encryptionKey) || Buffer.from(encryptionKey, "base64").length !== 32) invalid("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY");
} catch { invalid("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"); }

const mollieEnabled = required("MOLLIE_ENABLED");
const mollieKey = optional("MOLLIE_API_KEY");
if (!["true", "false"].includes(mollieEnabled)) invalid("MOLLIE_ENABLED");
if (mollieEnabled === "true" && !mollieKey) invalid("MOLLIE_API_KEY");
if (environment === "staging" && mollieKey && !mollieKey.startsWith("test_")) invalid("MOLLIE_API_KEY");
if (environment === "production" && mollieEnabled === "true" && !mollieKey.startsWith("live_")) invalid("MOLLIE_API_KEY");

const emailEnabled = required("EMAIL_ENABLED");
const sendgridKey = optional("SENDGRID_API_KEY");
const sendgridKeyFingerprint =
  optional("SENDGRID_API_KEY_FINGERPRINT");
const sendgridApiBaseUrl = optional("SENDGRID_API_BASE_URL") || "https://api.sendgrid.com";
const fromName = optional("SENDGRID_FROM_NAME");
const fromEmail = optional("SENDGRID_FROM_EMAIL");
const replyEmail = optional("SENDGRID_REPLY_TO_EMAIL");
const smokeRecipient = optional("SENDGRID_SMOKE_RECIPIENT");
const webhookKey = optional("SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY");
if (!["true", "false"].includes(emailEnabled)) invalid("EMAIL_ENABLED");
if (!["https://api.sendgrid.com", "https://api.eu.sendgrid.com"].includes(sendgridApiBaseUrl)) invalid("SENDGRID_API_BASE_URL");
if (webhookKey) {
  try {
    const key = webhookKey.includes("BEGIN PUBLIC KEY")
      ? createPublicKey(webhookKey.replaceAll("\\n", "\n"))
      : createPublicKey({ key: Buffer.from(webhookKey, "base64"), format: "der", type: "spki" });
    if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") invalid("SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY");
  } catch { invalid("SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY"); }
}
if (emailEnabled === "true") {
  if (!sendgridKey.startsWith("SG.")) invalid("SENDGRID_API_KEY");
  if (!/^[a-f0-9]{64}$/.test(sendgridKeyFingerprint)) {
    invalid("SENDGRID_API_KEY_FINGERPRINT");
  } else if (
    createHash("sha256").update(sendgridKey).digest("hex")
      !== sendgridKeyFingerprint
  ) {
    invalid("SENDGRID_API_KEY_FINGERPRINT");
  }
  if (!fromName || fromName.length > 120 || /[\r\n]/.test(fromName)) invalid("SENDGRID_FROM_NAME");
  if (!fromEmail) invalid("SENDGRID_FROM_EMAIL");
  if (!replyEmail) invalid("SENDGRID_REPLY_TO_EMAIL");
  if (environment === "staging" && !smokeRecipient) {
    invalid("SENDGRID_SMOKE_RECIPIENT");
  }
  if (!webhookKey) invalid("SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY");
}
for (const [name, value] of [["SENDGRID_FROM_EMAIL", fromEmail], ["SENDGRID_REPLY_TO_EMAIL", replyEmail], ["SENDGRID_SMOKE_RECIPIENT", smokeRecipient]]) {
  if (value && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) invalid(name);
}

if (errors.size) {
  console.error("Runtime-preflight mislukt voor:");
  for (const name of [...errors].sort()) console.error(`- ${name}`);
  process.exit(1);
}

if (process.argv[2] === "validate") {
  console.log(`Runtime-preflight voor ${environment} is geslaagd.`);
  process.exit(0);
}
if (process.argv[2] !== "write-runtime" || !process.argv[3]) {
  console.error("Gebruik: configure-runtime.mjs validate | write-runtime <pad>");
  process.exit(2);
}

const target = path.resolve(process.argv[3]);
if (target !== path.join(expected.root, ".env.runtime")) {
  console.error("Ongeldig runtimebestandpad.");
  process.exit(1);
}
const runtime = {
  NODE_ENV: "production",
  HOSTNAME: "0.0.0.0",
  PORT: "3000",
  APP_ENVIRONMENT: environment,
  RELEASE_SHA: releaseSha,
  RELEASE_ARTIFACT_DIGEST: releaseArtifactDigest,
  APP_BASE_URL: appUrl,
  NEXT_PUBLIC_SUPABASE_URL: supabaseUrl,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  SUPABASE_SECRET_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_JWKS: supabaseJwks,
  NEXT_SERVER_ACTIONS_ENCRYPTION_KEY: encryptionKey,
  PARENT_TOKEN_PEPPER: process.env.PARENT_TOKEN_PEPPER,
  QR_TOKEN_PEPPER: qrTokenPepper,
  QR_TOKEN_PEPPER_VERSION: qrTokenPepperVersion,
  CRON_SECRET: process.env.CRON_SECRET,
  DYNAMIC_IMPORT_ENABLED: dynamicImportEnabled,
  IMPORT_RAW_RETENTION_HOURS: importRetentionHours,
  OPERATIONS_INTERNAL_BASE_URL: "http://app:3000",
  MOLLIE_ENABLED: mollieEnabled,
  EMAIL_ENABLED: emailEnabled,
  ...Object.fromEntries([
    ["MOLLIE_API_KEY", mollieKey],
    ["SENDGRID_API_KEY", sendgridKey],
    ["SENDGRID_API_KEY_FINGERPRINT", sendgridKeyFingerprint],
    ["SENDGRID_API_BASE_URL", sendgridApiBaseUrl],
    ["SENDGRID_FROM_NAME", fromName],
    ["SENDGRID_FROM_EMAIL", fromEmail],
    ["SENDGRID_REPLY_TO_EMAIL", replyEmail],
    ["SENDGRID_SMOKE_RECIPIENT", smokeRecipient],
    ["SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY", webhookKey],
    ["OPERATIONS_HEARTBEAT_URL", operationsHeartbeatUrl],
    ["IMPORT_STAGING_ENCRYPTION_KEY", importStagingKey],
    ["QR_TOKEN_PREVIOUS_PEPPER", previousQrTokenPepper],
    ["QR_TOKEN_PREVIOUS_PEPPER_VERSION", previousQrTokenPepperVersion],
  ].filter(([, value]) => value)),
};
await mkdir(expected.root, { recursive: true, mode: 0o700 });
const temporary = `${target}.tmp-${process.pid}`;
await writeFile(temporary, `${Object.entries(runtime).map(([name, value]) => `${name}=${String(value ?? "")}`).join("\n")}\n`, { mode: 0o600 });
await chmod(temporary, 0o600);
await rename(temporary, target);
await chmod(target, 0o600);
console.log(`Runtimebestand voor ${environment} is atomisch geschreven.`);
