import { appendFile, writeFile } from "node:fs/promises";
import { createPublicKey } from "node:crypto";
import { pathToFileURL } from "node:url";

const webhookIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowedApiBaseUrls = new Set(["https://api.sendgrid.com", "https://api.eu.sendgrid.com"]);
const expectedEventSettings = {
  delivered: true,
  bounce: true,
  deferred: true,
  dropped: true,
  processed: false,
  spam_report: false,
  unsubscribe: false,
  group_unsubscribe: false,
  group_resubscribe: false,
  open: false,
  click: false,
  account_status_change: false,
};

function assertPublicKey(value) {
  if (typeof value !== "string" || value.length < 40 || value.length > 4_096) {
    throw new Error("SENDGRID_WEBHOOK_PUBLIC_KEY_INVALID");
  }
  let key;
  try {
    key = value.includes("BEGIN PUBLIC KEY")
      ? createPublicKey(value.replaceAll("\\n", "\n"))
      : createPublicKey({ key: Buffer.from(value, "base64"), format: "der", type: "spki" });
  } catch {
    throw new Error("SENDGRID_WEBHOOK_PUBLIC_KEY_INVALID");
  }
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("SENDGRID_WEBHOOK_PUBLIC_KEY_INVALID");
  }
  return value;
}

function validateInput(input) {
  if (!input.apiKey?.startsWith("SG.")) throw new Error("SENDGRID_API_KEY_INVALID");
  if (!allowedApiBaseUrls.has(input.apiBaseUrl)) throw new Error("SENDGRID_API_BASE_URL_INVALID");
  if (!webhookIdPattern.test(input.webhookId)) throw new Error("SENDGRID_WEBHOOK_ID_INVALID");
  let webhookUrl;
  try { webhookUrl = new URL(input.webhookUrl); }
  catch { throw new Error("SENDGRID_WEBHOOK_URL_INVALID"); }
  if (webhookUrl.protocol !== "https:" || webhookUrl.pathname !== "/api/webhooks/sendgrid" || webhookUrl.search || webhookUrl.hash) {
    throw new Error("SENDGRID_WEBHOOK_URL_INVALID");
  }
  return { ...input, webhookUrl: webhookUrl.toString() };
}

async function providerRequest(input, path, method = "GET", body) {
  const response = await input.fetchImpl(`${input.apiBaseUrl}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${input.apiKey}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) throw new Error(`SENDGRID_WEBHOOK_PROVIDER_${response.status}`);
  try { return await response.json(); }
  catch { throw new Error("SENDGRID_WEBHOOK_PROVIDER_RESPONSE_INVALID"); }
}

function assertSettings(settings, input) {
  const invalidFields = [];
  if (settings?.id !== input.webhookId) invalidFields.push("id");
  if (settings?.enabled !== true) invalidFields.push("enabled");
  if (settings?.url !== input.webhookUrl) invalidFields.push("url");
  for (const [name, expected] of Object.entries(expectedEventSettings)) {
    const actual = settings?.[name] ?? false;
    if (actual !== expected) invalidFields.push(name);
  }
  if (invalidFields.length > 0) throw new Error(`SENDGRID_WEBHOOK_SETTINGS_INVALID:${invalidFields.join(",")}`);
}

export async function configureSendGridWebhook(rawInput) {
  const input = validateInput({ ...rawInput, fetchImpl: rawInput.fetchImpl ?? fetch });
  const settingsPath = `/v3/user/webhooks/event/settings/${input.webhookId}`;
  const signingPath = `/v3/user/webhooks/event/settings/signed/${input.webhookId}`;
  const settingsBody = { enabled: true, url: input.webhookUrl, ...expectedEventSettings };

  await providerRequest(input, settingsPath, "PATCH", settingsBody);
  const signing = await providerRequest(input, signingPath, "PATCH", { enabled: true });
  const publicKey = assertPublicKey(signing?.public_key);
  if (signing?.id !== input.webhookId) throw new Error("SENDGRID_WEBHOOK_SIGNING_INVALID");

  const settings = await providerRequest(input, settingsPath);
  assertSettings(settings, input);
  const verifiedSigning = await providerRequest(input, signingPath);
  if (verifiedSigning?.id !== input.webhookId || assertPublicKey(verifiedSigning?.public_key) !== publicKey) {
    throw new Error("SENDGRID_WEBHOOK_SIGNING_INVALID");
  }
  return { publicKey };
}

async function main() {
  const result = await configureSendGridWebhook({
    apiKey: process.env.SENDGRID_API_KEY,
    apiBaseUrl: process.env.SENDGRID_API_BASE_URL,
    webhookId: process.env.SENDGRID_WEBHOOK_ID,
    webhookUrl: process.env.SENDGRID_WEBHOOK_URL,
  });
  if (process.env.SENDGRID_PUBLIC_KEY_FILE) {
    await writeFile(process.env.SENDGRID_PUBLIC_KEY_FILE, `${result.publicKey}\n`, { mode: 0o600 });
  }
  if (process.env.GITHUB_OUTPUT) {
    await appendFile(process.env.GITHUB_OUTPUT, `public_key<<SENDGRID_PUBLIC_KEY\n${result.publicKey}\nSENDGRID_PUBLIC_KEY\n`);
  }
  console.log("SendGrid stagingwebhook, eventselectie en signing zijn gevalideerd.");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "SENDGRID_WEBHOOK_CONFIGURATION_FAILED");
    process.exit(1);
  });
}
