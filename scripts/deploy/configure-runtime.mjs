import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";

const environment = process.env.DEPLOY_ENVIRONMENT;
const expected = {
  staging: {
    root: "/srv/duindorp-tenueportaal/staging",
    service: "duindorp-tenueportaal-staging.service",
  },
  production: {
    root: "/srv/duindorp-tenueportaal/production",
    service: "duindorp-tenueportaal-production.service",
  },
};

const errors = [];

function value(name, minimum = 1) {
  const candidate = process.env[name]?.trim();
  if (!candidate || candidate.length < minimum) {
    errors.push(`${name} ontbreekt of is te kort`);
    return "";
  }
  if (candidate.includes("\0") || candidate.includes("\r") || candidate.includes("\n")) {
    errors.push(`${name} mag geen regeleinden bevatten`);
    return "";
  }
  return candidate;
}

function optional(name) {
  const candidate = process.env[name]?.trim() ?? "";
  if (candidate.includes("\0") || candidate.includes("\r") || candidate.includes("\n")) {
    errors.push(`${name} mag geen regeleinden bevatten`);
    return "";
  }
  return candidate;
}

function httpsOrigin(name) {
  const candidate = value(name);
  try {
    const parsed = new URL(candidate);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.pathname !== "/" || parsed.search || parsed.hash) {
      errors.push(`${name} moet een publieke HTTPS-origin zonder pad zijn`);
    }
  } catch {
    errors.push(`${name} is geen geldige URL`);
  }
  return candidate;
}

function booleanFlag(name) {
  const candidate = value(name);
  if (candidate !== "true" && candidate !== "false") errors.push(`${name} moet true of false zijn`);
  return candidate;
}

if (!(environment in expected)) errors.push("DEPLOY_ENVIRONMENT moet staging of production zijn");

const config = environment in expected ? expected[environment] : { root: "", service: "" };
const deployRoot = value("DEPLOY_ROOT");
if (deployRoot !== config.root) errors.push(`DEPLOY_ROOT moet voor ${environment ?? "de omgeving"} exact ${config.root || "de vaste projectmap"} zijn`);

const service = value("SYSTEMD_SERVICE");
if (service !== config.service) errors.push(`SYSTEMD_SERVICE moet voor ${environment ?? "de omgeving"} exact ${config.service || "de vaste servicenaam"} zijn`);

const deploySha = value("DEPLOY_SHA");
if (!/^[a-f0-9]{40}$/.test(deploySha)) errors.push("DEPLOY_SHA moet een volledige Git commit-SHA zijn");

const appPort = value("APP_PORT");
const numericPort = Number(appPort);
if (!Number.isInteger(numericPort) || numericPort < 1024 || numericPort > 65535) errors.push("APP_PORT moet een niet-bevoorrechte TCP-poort zijn");

const appBaseUrl = httpsOrigin("APP_BASE_URL");
const supabaseUrl = httpsOrigin("NEXT_PUBLIC_SUPABASE_URL");
const publishableKey = value("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", 20);
const supabaseSecretKey = value("SUPABASE_SECRET_KEY", 20);
const parentTokenPepper = value("PARENT_TOKEN_PEPPER", 32);
const cronSecret = value("CRON_SECRET", 16);
const supabaseAccessToken = value("SUPABASE_ACCESS_TOKEN", 20);
const supabaseDbPassword = value("SUPABASE_DB_PASSWORD", 8);
const supabaseProjectId = value("SUPABASE_PROJECT_ID");
if (!/^[a-z0-9]{20}$/.test(supabaseProjectId)) errors.push("SUPABASE_PROJECT_ID moet een Supabase-projectreferentie van twintig tekens zijn");

const mollieEnabled = booleanFlag("MOLLIE_ENABLED");
const mollieApiKey = optional("MOLLIE_API_KEY");
if (mollieEnabled === "true" && !mollieApiKey) errors.push("MOLLIE_API_KEY is verplicht wanneer Mollie actief is");
if (environment === "staging" && mollieApiKey && !mollieApiKey.startsWith("test_")) errors.push("Staging accepteert uitsluitend een Mollie test-key");
if (environment === "production" && mollieEnabled === "true" && !mollieApiKey.startsWith("live_")) errors.push("Actieve Mollie-productie vereist een live-key");

const emailEnabled = booleanFlag("EMAIL_ENABLED");
const sendGridApiKey = optional("SENDGRID_API_KEY");
const sendGridFromEmail = optional("SENDGRID_FROM_EMAIL");
const sendGridReplyToEmail = optional("SENDGRID_REPLY_TO_EMAIL");
const sendGridWebhookKey = optional("SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY");

if (emailEnabled === "true") {
  for (const [name, candidate] of [
    ["SENDGRID_API_KEY", sendGridApiKey],
    ["SENDGRID_FROM_EMAIL", sendGridFromEmail],
    ["SENDGRID_REPLY_TO_EMAIL", sendGridReplyToEmail],
    ["SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY", sendGridWebhookKey],
  ]) {
    if (!candidate) errors.push(`${name} is verplicht wanneer e-mail actief is`);
  }
}

for (const [name, candidate] of [["SENDGRID_FROM_EMAIL", sendGridFromEmail], ["SENDGRID_REPLY_TO_EMAIL", sendGridReplyToEmail]]) {
  if (candidate && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(candidate)) errors.push(`${name} is geen geldig e-mailadres`);
}

// Keep references alive so static review makes every validated deployment input explicit.
void [appBaseUrl, supabaseUrl, publishableKey, supabaseSecretKey, parentTokenPepper, cronSecret, supabaseAccessToken, supabaseDbPassword];

if (errors.length) {
  console.error("Deployconfiguratie ongeldig:");
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

if (process.argv[2] === "validate") {
  console.log(`Deployconfiguratie voor ${environment} is volledig en geldig.`);
  process.exit(0);
}

if (process.argv[2] !== "write-runtime" || !process.argv[3]) {
  console.error("Gebruik: configure-runtime.mjs validate | write-runtime <bestand>");
  process.exit(2);
}

const target = path.resolve(process.argv[3]);
const sharedRoot = path.join(config.root, "shared");
if (path.dirname(target) !== sharedRoot || path.basename(target) !== "app.env") {
  console.error(`Runtimeconfiguratie mag uitsluitend naar ${sharedRoot}/app.env worden geschreven.`);
  process.exit(1);
}

const runtime = {
  NODE_ENV: "production",
  HOSTNAME: "127.0.0.1",
  PORT: appPort,
  APP_BASE_URL: appBaseUrl,
  NEXT_PUBLIC_SUPABASE_URL: supabaseUrl,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: publishableKey,
  SUPABASE_SECRET_KEY: supabaseSecretKey,
  PARENT_TOKEN_PEPPER: parentTokenPepper,
  CRON_SECRET: cronSecret,
  MOLLIE_ENABLED: mollieEnabled,
  MOLLIE_API_KEY: mollieApiKey,
  EMAIL_ENABLED: emailEnabled,
  SENDGRID_API_KEY: sendGridApiKey,
  SENDGRID_FROM_EMAIL: sendGridFromEmail,
  SENDGRID_REPLY_TO_EMAIL: sendGridReplyToEmail,
  SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: sendGridWebhookKey,
  RELEASE_SHA: deploySha,
};

function quote(candidate) {
  return `"${candidate.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

await mkdir(sharedRoot, { recursive: true, mode: 0o700 });
const temporary = `${target}.tmp-${process.pid}`;
const contents = `${Object.entries(runtime).map(([name, candidate]) => `${name}=${quote(candidate)}`).join("\n")}\n`;
await writeFile(temporary, contents, { encoding: "utf8", mode: 0o600 });
await chmod(temporary, 0o600);
await rename(temporary, target);
console.log(`Runtimeconfiguratie voor ${environment} is atomair bijgewerkt.`);
