import {
  createHash,
  timingSafeEqual,
} from "node:crypto";
import { pathToFileURL } from "node:url";

const allowedApiBaseUrls = new Set([
  "https://api.sendgrid.com",
  "https://api.eu.sendgrid.com",
]);
const fingerprintPattern = /^[a-f0-9]{64}$/u;
const expectedAdminScopes = [
  "user.username.read",
  "user.webhooks.event.settings.read",
  "user.webhooks.event.settings.update",
];

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name}_MISSING`);
  return value;
}

function equalFingerprint(actual, expected) {
  if (
    !fingerprintPattern.test(actual)
    || !fingerprintPattern.test(expected)
  ) {
    return false;
  }
  return timingSafeEqual(
    Buffer.from(actual, "hex"),
    Buffer.from(expected, "hex"),
  );
}

function fingerprint(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function validateSendGridFingerprintConfig(values) {
  const config = {
    apiBaseUrl: required(values, "SENDGRID_API_BASE_URL")
      .replace(/\/$/u, ""),
    apiKey: required(values, "SENDGRID_API_KEY"),
    adminApiKey: required(values, "SENDGRID_ADMIN_API_KEY"),
    apiKeyFingerprint: required(
      values,
      "SENDGRID_API_KEY_FINGERPRINT",
    ).toLowerCase(),
    expectedAccountFingerprint: required(
      values,
      "SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT",
    ).toLowerCase(),
  };
  if (
    !allowedApiBaseUrls.has(config.apiBaseUrl)
    || !config.apiKey.startsWith("SG.")
    || !config.adminApiKey.startsWith("SG.")
    || config.apiKey === config.adminApiKey
    || !fingerprintPattern.test(config.apiKeyFingerprint)
    || !fingerprintPattern.test(config.expectedAccountFingerprint)
  ) {
    throw new Error("SENDGRID_FINGERPRINT_CONFIG_INVALID");
  }
  if (!equalFingerprint(
    fingerprint(config.apiKey),
    config.apiKeyFingerprint,
  )) {
    throw new Error("SENDGRID_API_KEY_FINGERPRINT_MISMATCH");
  }
  return config;
}

async function providerRequest(
  config,
  apiKey,
  path,
  fetchImpl,
) {
  const response = await fetchImpl(
    `${config.apiBaseUrl}${path}`,
    {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(20_000),
    },
  );
  if (!response.ok) {
    throw new Error(`SENDGRID_PROVIDER_HTTP_${response.status}`);
  }
  try {
    return await response.json();
  } catch {
    throw new Error("SENDGRID_PROVIDER_RESPONSE_INVALID");
  }
}

export async function verifySendGridFingerprints(
  values,
  fetchImpl = fetch,
) {
  const config = validateSendGridFingerprintConfig(values);
  const identity = await providerRequest(
    config,
    config.adminApiKey,
    "/v3/user/username",
    fetchImpl,
  );
  if (
    typeof identity?.username !== "string"
    || identity.username.trim() !== identity.username
    || !/^[^\s:]{1,128}$/u.test(identity.username)
    || !Number.isSafeInteger(identity?.user_id)
    || identity.user_id <= 0
  ) {
    throw new Error("SENDGRID_ACCOUNT_IDENTITY_INVALID");
  }
  const accountFingerprint = fingerprint(
    `${identity.username}:${identity.user_id}`,
  );
  if (!equalFingerprint(
    accountFingerprint,
    config.expectedAccountFingerprint,
  )) {
    throw new Error("SENDGRID_ACCOUNT_IDENTITY_MISMATCH");
  }

  const scopes = await providerRequest(
    config,
    config.apiKey,
    "/v3/scopes",
    fetchImpl,
  );
  if (
    !Array.isArray(scopes?.scopes)
    || scopes.scopes.length !== 1
    || scopes.scopes[0] !== "mail.send"
  ) {
    throw new Error("SENDGRID_APP_KEY_SCOPE_NOT_MINIMAL");
  }

  const adminScopes = await providerRequest(
    config,
    config.adminApiKey,
    "/v3/scopes",
    fetchImpl,
  );
  if (
    !Array.isArray(adminScopes?.scopes)
    || adminScopes.scopes.length !== expectedAdminScopes.length
    || [...adminScopes.scopes].sort().some(
      (scope, index) => scope !== expectedAdminScopes[index],
    )
  ) {
    throw new Error("SENDGRID_ADMIN_KEY_SCOPE_NOT_MINIMAL");
  }
}

async function main() {
  await verifySendGridFingerprints(process.env);
  console.log(
    "SendGrid-keyfingerprints, minimale scopes en staging-adminkeyaccount zijn geverifieerd; dezelfde-accountbinding volgt uitsluitend uit de volledige provideracceptatie.",
  );
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    const message = error instanceof Error
      && /^SENDGRID_[A-Z0-9_]+$/u.test(error.message)
      ? error.message
      : "SENDGRID_FINGERPRINT_VERIFICATION_FAILED";
    console.error(message);
    process.exit(1);
  });
}
