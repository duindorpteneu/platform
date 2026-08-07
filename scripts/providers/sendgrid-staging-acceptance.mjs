import {
  createHash,
  createHmac,
  createPublicKey,
  randomUUID,
} from "node:crypto";
import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { createServerClient } from "@supabase/ssr";
import { ImapFlow } from "imapflow";

const allowedApiBases = new Set([
  "https://api.sendgrid.com",
  "https://api.eu.sendgrid.com",
]);
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const releasePattern = /^[a-f0-9]{40}$/u;
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

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name}_MISSING`);
  return value;
}

function validatedPublicKey(value, name) {
  try {
    const key = value.includes("BEGIN PUBLIC KEY")
      ? createPublicKey(value.replaceAll("\\n", "\n"))
      : createPublicKey({
          key: Buffer.from(value, "base64"),
          format: "der",
          type: "spki",
        });
    if (
      key.asymmetricKeyType !== "ec"
      || key.asymmetricKeyDetails?.namedCurve !== "prime256v1"
    ) {
      throw new Error("curve");
    }
    return createHash("sha256")
      .update(key.export({ type: "spki", format: "der" }))
      .digest("hex");
  } catch {
    throw new Error(`${name}_INVALID`);
  }
}

export function validateSendGridAcceptanceConfig(values) {
  const config = {
    apiKey: required(values, "SENDGRID_API_KEY"),
    adminApiKey: required(values, "SENDGRID_ADMIN_API_KEY"),
    apiKeyFingerprint:
      required(values, "SENDGRID_API_KEY_FINGERPRINT").toLowerCase(),
    apiBaseUrl: required(
      values,
      "SENDGRID_API_BASE_URL",
    ).replace(/\/$/u, ""),
    expectedAccountFingerprint:
      required(values, "SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT"),
    fromName: required(values, "SENDGRID_FROM_NAME"),
    fromEmail:
      required(values, "SENDGRID_FROM_EMAIL").toLowerCase(),
    replyToEmail:
      required(values, "SENDGRID_REPLY_TO_EMAIL").toLowerCase(),
    recipient:
      required(values, "SENDGRID_SMOKE_RECIPIENT").toLowerCase(),
    webhookId: required(values, "SENDGRID_WEBHOOK_ID"),
    webhookUrl: required(values, "SENDGRID_WEBHOOK_URL"),
    webhookPublicKey:
      required(values, "SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY"),
    stagingBaseUrl: required(values, "STAGING_BASE_URL"),
    releaseSha: required(values, "RELEASE_SHA").toLowerCase(),
    supabaseUrl: required(values, "NEXT_PUBLIC_SUPABASE_URL"),
    supabaseAnonKey:
      required(values, "NEXT_PUBLIC_SUPABASE_ANON_KEY"),
    adminEmail:
      required(values, "E2E_ADMIN_EMAIL").toLowerCase(),
    adminPassword: required(values, "E2E_ADMIN_PASSWORD"),
    adminTotpSecret: required(
      values,
      "E2E_ADMIN_TOTP_SECRET",
    ).replaceAll(/\s/gu, "").toUpperCase(),
    imapHost: required(values, "E2E_MAILBOX_IMAP_HOST"),
    imapPort: Number(required(values, "E2E_MAILBOX_IMAP_PORT")),
    imapUser: required(values, "E2E_MAILBOX_IMAP_USER"),
    imapPassword: required(values, "E2E_MAILBOX_IMAP_PASSWORD"),
    imapMailbox:
      values.E2E_MAILBOX_IMAP_MAILBOX?.trim() || "INBOX",
  };
  let webhookUrl;
  let stagingBaseUrl;
  let supabaseUrl;
  try {
    webhookUrl = new URL(config.webhookUrl);
    stagingBaseUrl = new URL(config.stagingBaseUrl);
    supabaseUrl = new URL(config.supabaseUrl);
  } catch {
    throw new Error("SENDGRID_ACCEPTANCE_URL_INVALID");
  }
  const appKeyFingerprint = createHash("sha256")
    .update(config.apiKey)
    .digest("hex");
  if (
    !config.apiKey.startsWith("SG.")
    || !config.adminApiKey.startsWith("SG.")
    || config.apiKey === config.adminApiKey
    || !allowedApiBases.has(config.apiBaseUrl)
    || !/^[a-f0-9]{64}$/u.test(config.apiKeyFingerprint)
    || appKeyFingerprint !== config.apiKeyFingerprint
    || !/^[a-f0-9]{64}$/u.test(config.expectedAccountFingerprint)
    || config.fromName !== "Kledingcommissie Duindorp SV"
    || config.fromEmail !== "kleding@duindorpsv.nl"
    || config.replyToEmail !== "kleding@duindorpsv.nl"
    || !emailPattern.test(config.recipient)
    || !emailPattern.test(config.adminEmail)
    || config.adminPassword.length < 12
    || !/^[A-Z2-7]{16,128}$/u.test(config.adminTotpSecret)
    || !uuidPattern.test(config.webhookId)
    || !releasePattern.test(config.releaseSha)
    || webhookUrl.protocol !== "https:"
    || webhookUrl.pathname !== "/api/webhooks/sendgrid"
    || webhookUrl.search
    || webhookUrl.hash
    || stagingBaseUrl.protocol !== "https:"
    || stagingBaseUrl.origin
      !== "https://staging-duindorp.dgwebservices.nl"
    || stagingBaseUrl.pathname !== "/"
    || stagingBaseUrl.search
    || stagingBaseUrl.hash
    || webhookUrl.origin !== stagingBaseUrl.origin
    || supabaseUrl.protocol !== "https:"
    || !/^[a-z0-9]{20}\.supabase\.co$/u.test(supabaseUrl.hostname)
    || supabaseUrl.pathname !== "/"
    || supabaseUrl.search
    || supabaseUrl.hash
    || config.supabaseAnonKey.length < 20
    || !/^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$/u.test(config.imapHost)
    || !Number.isSafeInteger(config.imapPort)
    || config.imapPort !== 993
    || config.imapMailbox.length > 128
    || /[\u0000-\u001f\u007f]/u.test(config.imapMailbox)
  ) {
    throw new Error("SENDGRID_ACCEPTANCE_CONFIG_INVALID");
  }
  return {
    ...config,
    webhookUrl: webhookUrl.toString(),
    stagingBaseUrl: stagingBaseUrl.toString(),
    supabaseUrl: supabaseUrl.toString(),
    webhookPublicKeyFingerprint: validatedPublicKey(
      config.webhookPublicKey,
      "SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY",
    ),
  };
}

async function providerRequest(
  config,
  apiKey,
  path,
  fetchImpl = fetch,
) {
  return fetchImpl(`${config.apiBaseUrl}${path}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(20_000),
  });
}

export async function runSendGridProviderChecks(
  config,
  fetchImpl = fetch,
) {
  const identityResponse = await providerRequest(
    config,
    config.adminApiKey,
    "/v3/user/username",
    fetchImpl,
  );
  if (!identityResponse.ok) {
    throw new Error(
      `SENDGRID_IDENTITY_HTTP_${identityResponse.status}`,
    );
  }
  const identity = await identityResponse.json();
  const identityFingerprint = createHash("sha256")
    .update(`${identity?.username ?? ""}:${identity?.user_id ?? ""}`)
    .digest("hex");
  if (identityFingerprint !== config.expectedAccountFingerprint) {
    throw new Error("SENDGRID_ACCOUNT_IDENTITY_MISMATCH");
  }

  const scopesResponse = await providerRequest(
    config,
    config.apiKey,
    "/v3/scopes",
    fetchImpl,
  );
  if (!scopesResponse.ok) {
    throw new Error(
      `SENDGRID_SCOPES_HTTP_${scopesResponse.status}`,
    );
  }
  const scopes = await scopesResponse.json();
  if (
    !Array.isArray(scopes?.scopes)
    || scopes.scopes.length !== 1
    || scopes.scopes[0] !== "mail.send"
  ) {
    throw new Error("SENDGRID_APP_KEY_SCOPE_NOT_MINIMAL");
  }

  const settingsResponse = await providerRequest(
    config,
    config.adminApiKey,
    `/v3/user/webhooks/event/settings/${config.webhookId}`,
    fetchImpl,
  );
  if (!settingsResponse.ok) {
    throw new Error(
      `SENDGRID_WEBHOOK_SETTINGS_HTTP_${settingsResponse.status}`,
    );
  }
  const settings = await settingsResponse.json();
  if (
    settings?.id !== config.webhookId
    || settings?.enabled !== true
    || settings?.url !== config.webhookUrl
    || Object.entries(expectedEventSettings).some(
      ([name, expected]) => (settings?.[name] ?? false) !== expected,
    )
  ) {
    throw new Error("SENDGRID_WEBHOOK_SETTINGS_INVALID");
  }

  const signingResponse = await providerRequest(
    config,
    config.adminApiKey,
    `/v3/user/webhooks/event/settings/signed/${config.webhookId}`,
    fetchImpl,
  );
  if (!signingResponse.ok) {
    throw new Error(
      `SENDGRID_WEBHOOK_SIGNING_HTTP_${signingResponse.status}`,
    );
  }
  const signing = await signingResponse.json();
  if (
    signing?.id !== config.webhookId
    || signing?.enabled !== true
    || validatedPublicKey(
      signing?.public_key,
      "SENDGRID_PROVIDER_WEBHOOK_PUBLIC_KEY",
    ) !== config.webhookPublicKeyFingerprint
  ) {
    throw new Error("SENDGRID_WEBHOOK_SIGNING_INVALID");
  }
}

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value) {
    const index = alphabet.indexOf(character);
    if (index < 0) throw new Error("E2E_ADMIN_TOTP_SECRET_INVALID");
    bits += index.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8) {
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  }
  return Buffer.from(bytes);
}

function currentTotp(secret, now = Date.now()) {
  const counter = Math.floor(now / 30_000);
  const counterBuffer = Buffer.alloc(8);
  counterBuffer.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", decodeBase32(secret))
    .update(counterBuffer)
    .digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary = (
    ((digest[offset] & 0x7f) << 24)
    | ((digest[offset + 1] & 0xff) << 16)
    | ((digest[offset + 2] & 0xff) << 8)
    | (digest[offset + 3] & 0xff)
  ) % 1_000_000;
  return String(binary).padStart(6, "0");
}

function cookieHeader(cookies) {
  return [...cookies.entries()]
    .map(([name, value]) => `${name}=${value}`)
    .join("; ");
}

export async function createAal2AdminSession(
  config,
  dependencies = {},
) {
  const cookies = new Map();
  const createClient = dependencies.createClient ?? createServerClient;
  const client = createClient(
    config.supabaseUrl,
    config.supabaseAnonKey,
    {
      auth: {
        autoRefreshToken: false,
        detectSessionInUrl: false,
        persistSession: true,
      },
      cookies: {
        getAll: () => [...cookies.entries()].map(
          ([name, value]) => ({ name, value }),
        ),
        setAll: (values) => {
          for (const { name, value } of values) {
            if (value) cookies.set(name, value);
            else cookies.delete(name);
          }
        },
      },
    },
  );
  const signedIn = await client.auth.signInWithPassword({
    email: config.adminEmail,
    password: config.adminPassword,
  });
  if (signedIn.error || !signedIn.data.session) {
    throw new Error("E2E_ADMIN_SIGN_IN_FAILED");
  }
  const aal = await client.auth.mfa.getAuthenticatorAssuranceLevel();
  if (aal.error || aal.data.nextLevel !== "aal2") {
    throw new Error("E2E_ADMIN_MFA_POLICY_INVALID");
  }
  if (aal.data.currentLevel !== "aal2") {
    const factors = await client.auth.mfa.listFactors();
    const verifiedTotp = factors.data?.totp?.filter(
      (factor) => factor.status === "verified",
    ) ?? [];
    if (factors.error || verifiedTotp.length !== 1) {
      throw new Error("E2E_ADMIN_MFA_FACTOR_INVALID");
    }
    const verified = await client.auth.mfa.challengeAndVerify({
      factorId: verifiedTotp[0].id,
      code: currentTotp(
        config.adminTotpSecret,
        dependencies.now?.() ?? Date.now(),
      ),
    });
    if (verified.error) {
      throw new Error("E2E_ADMIN_MFA_VERIFY_FAILED");
    }
  }
  const session = await client.auth.getSession();
  if (
    session.error
    || !session.data.session?.access_token
  ) {
    throw new Error("E2E_ADMIN_SESSION_UNAVAILABLE");
  }

  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const appSessionResponse = await fetchImpl(
    new URL("/api/staff-auth/session", config.stagingBaseUrl),
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Cookie: cookieHeader(cookies),
        Origin: new URL(config.stagingBaseUrl).origin,
      },
      body: JSON.stringify({
        accessToken: session.data.session.access_token,
      }),
      signal: AbortSignal.timeout(20_000),
    },
  );
  if (!appSessionResponse.ok) {
    throw new Error(
      `E2E_APP_SESSION_HTTP_${appSessionResponse.status}`,
    );
  }
  const setCookies =
    appSessionResponse.headers.getSetCookie?.()
      ?? [appSessionResponse.headers.get("set-cookie")].filter(Boolean);
  const appSession = setCookies
    .map((value) => value.match(
      /(?:^|,\s*)duindorp_staff_session=([^;,\s]+)/u,
    )?.[1])
    .find(Boolean);
  if (!appSession) {
    throw new Error("E2E_APP_SESSION_COOKIE_MISSING");
  }
  cookies.set("duindorp_staff_session", appSession);
  return { client, cookies };
}

export async function sendApplicationTestMail(
  config,
  correlation,
  session,
  dependencies = {},
) {
  const workspace = await session.client
    .schema("app")
    .rpc("get_mail_workspace_v1");
  const template = workspace.data?.templates?.find(
    (item) => item?.key === "package_complete",
  );
  const branding = workspace.data?.branding?.published;
  if (
    workspace.error
    || workspace.data?.featureEnabled !== true
    || !template?.published?.contentHash
    || branding?.fromName !== config.fromName
    || branding?.fromEmail !== config.fromEmail
    || branding?.replyToEmail !== config.replyToEmail
  ) {
    throw new Error("E2E_MAIL_WORKSPACE_NOT_READY");
  }
  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const response = await fetchImpl(
    new URL(
      "/api/email/v2/test-delivery",
      config.stagingBaseUrl,
    ),
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Cookie: cookieHeader(session.cookies),
        Origin: new URL(config.stagingBaseUrl).origin,
        "X-Correlation-Id": correlation,
      },
      body: JSON.stringify({
        requestId: correlation,
        templateKey: "package_complete",
        expectedContentHash: template.published.contentHash,
      }),
      signal: AbortSignal.timeout(30_000),
    },
  );
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error("E2E_TEST_DELIVERY_RESPONSE_INVALID");
  }
  if (
    !response.ok
    || body?.status !== "accepted"
    || !uuidPattern.test(body?.deliveryId ?? "")
    || typeof body?.reused !== "boolean"
  ) {
    throw new Error(
      `E2E_TEST_DELIVERY_HTTP_${response.status}`,
    );
  }
  return {
    deliveryId: body.deliveryId,
    reused: body.reused,
  };
}

export async function waitForInboxMessage(
  config,
  deliveryId,
  dependencies = {},
) {
  const createClient = dependencies.createImapClient
    ?? ((options) => new ImapFlow(options));
  const sleep = dependencies.sleep
    ?? ((milliseconds) => new Promise(
      (resolve) => setTimeout(resolve, milliseconds),
    ));
  const attempts = dependencies.attempts ?? 24;
  const client = createClient({
    host: config.imapHost,
    port: config.imapPort,
    secure: true,
    auth: {
      user: config.imapUser,
      pass: config.imapPassword,
    },
    tls: {
      rejectUnauthorized: true,
      minVersion: "TLSv1.2",
    },
    logger: false,
    disableAutoIdle: true,
    connectionTimeout: 15_000,
    greetingTimeout: 15_000,
    socketTimeout: 30_000,
    maxLineLength: 64 * 1_024,
    maxLiteralSize: 2 * 1_024 * 1_024,
  });
  try {
    await client.connect();
    const lock = await client.getMailboxLock(
      config.imapMailbox,
      { readOnly: true },
    );
    try {
      for (let attempt = 0; attempt < attempts; attempt += 1) {
        const matches = await client.search({
          header: { "x-duindorp-acceptance": deliveryId },
        }, { uid: true });
        if (Array.isArray(matches) && matches.length === 1) {
          const message = await client.fetchOne(
            matches[0],
            { envelope: true, uid: true },
            { uid: true },
          );
          const from = message?.envelope?.from?.map(
            (entry) => entry.address?.toLowerCase(),
          );
          const to = message?.envelope?.to?.map(
            (entry) => entry.address?.toLowerCase(),
          );
          const subject = message?.envelope?.subject;
          if (
            typeof subject === "string"
            && subject.length >= 3
            && subject.length <= 200
            && from?.includes(config.fromEmail)
            && to?.includes(config.recipient)
          ) {
            return { messageCount: 1 };
          }
          throw new Error(
            "E2E_MAILBOX_MESSAGE_CONTRACT_INVALID",
          );
        }
        if (Array.isArray(matches) && matches.length > 1) {
          throw new Error(
            "E2E_MAILBOX_CORRELATION_NOT_UNIQUE",
          );
        }
        if (attempt + 1 < attempts) await sleep(5_000);
      }
    } finally {
      lock.release();
    }
    throw new Error("E2E_MAILBOX_DELIVERY_TIMEOUT");
  } finally {
    await client.logout().catch(() => undefined);
  }
}

export async function waitForSignedProviderEvent(
  session,
  deliveryId,
  dependencies = {},
) {
  const sleep = dependencies.sleep
    ?? ((milliseconds) => new Promise(
      (resolve) => setTimeout(resolve, milliseconds),
    ));
  const attempts = dependencies.attempts ?? 24;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const result = await session.client
      .schema("app")
      .rpc("get_mail_test_delivery_status_v2", {
        p_delivery_id: deliveryId,
      });
    if (result.error) {
      throw new Error("E2E_PROVIDER_EVENT_STATUS_FAILED");
    }
    const status = result.data;
    const counts = [
      status?.eventCount,
      status?.deliveredEventCount,
      status?.deferredEventCount,
      status?.failureEventCount,
      status?.quarantinedEventCount,
    ];
    if (
      !status
      || typeof status !== "object"
      || status.deliveryId !== deliveryId
      || typeof status.accepted !== "boolean"
      || !counts.every(
        (value) => Number.isSafeInteger(value) && value >= 0,
      )
      || status.eventCount
        !== status.deliveredEventCount
          + status.deferredEventCount
          + status.failureEventCount
    ) {
      throw new Error("E2E_PROVIDER_EVENT_STATUS_INVALID");
    }
    if (status.quarantinedEventCount > 0) {
      throw new Error("E2E_PROVIDER_EVENT_QUARANTINED");
    }
    if (status.failureEventCount > 0) {
      throw new Error("E2E_PROVIDER_DELIVERY_FAILED");
    }
    if (
      status.accepted
      && status.eventCount >= 1
      && status.deliveredEventCount >= 1
    ) {
      return {
        eventCount: status.eventCount,
        deliveredEventCount: status.deliveredEventCount,
        deferredEventCount: status.deferredEventCount,
        failureEventCount: status.failureEventCount,
        quarantinedEventCount: status.quarantinedEventCount,
      };
    }
    if (attempt + 1 < attempts) await sleep(5_000);
  }
  throw new Error("E2E_SIGNED_PROVIDER_EVENT_TIMEOUT");
}

export async function runSendGridAcceptance(
  values,
  dependencies = {},
) {
  const config = validateSendGridAcceptanceConfig(values);
  const correlation =
    (dependencies.randomUUID ?? randomUUID)();
  if (!uuidPattern.test(correlation)) {
    throw new Error(
      "SENDGRID_ACCEPTANCE_CORRELATION_INVALID",
    );
  }
  await runSendGridProviderChecks(
    config,
    dependencies.fetchImpl,
  );
  const session = await createAal2AdminSession(
    config,
    dependencies,
  );
  const firstDelivery = await sendApplicationTestMail(
    config,
    correlation,
    session,
    dependencies,
  );
  if (firstDelivery.reused) {
    throw new Error("E2E_TEST_DELIVERY_UNEXPECTED_REUSE");
  }
  const replayedDelivery = await sendApplicationTestMail(
    config,
    correlation,
    session,
    dependencies,
  );
  if (
    replayedDelivery.reused !== true
    || replayedDelivery.deliveryId !== firstDelivery.deliveryId
  ) {
    throw new Error("E2E_TEST_DELIVERY_REPLAY_INVALID");
  }
  const { deliveryId } = firstDelivery;
  const [inbox, provider] = await Promise.all([
    waitForInboxMessage(
      config,
      deliveryId,
      dependencies,
    ),
    waitForSignedProviderEvent(
      session,
      deliveryId,
      dependencies,
    ),
  ]);
  return {
    schema_version: 1,
    release_sha: config.releaseSha,
    checks: {
      account_identity: true,
      app_request_idempotency: true,
      inbox_delivery: true,
      mail_send_scope: true,
      signed_delivery_event: true,
      webhook_configuration: true,
    },
    delivery: {
      application_requests: 2,
      inbox_messages: inbox.messageCount,
      provider_events: provider.eventCount,
      delivered_events: provider.deliveredEventCount,
      deferred_events: provider.deferredEventCount,
      failure_events: provider.failureEventCount,
      quarantined_events: provider.quarantinedEventCount,
    },
  };
}

async function main() {
  const observation = await runSendGridAcceptance(process.env);
  const observationPath =
    process.env.SENDGRID_ACCEPTANCE_OBSERVATION_PATH?.trim();
  if (observationPath) {
    await writeFile(
      observationPath,
      `${JSON.stringify(observation, null, 2)}\n`,
      { mode: 0o600 },
    );
  }
  process.stdout.write(
    "SendGrid appkey, beheerder-MFA, idempotente app-testdelivery, exact één inboxbericht en gekoppeld signed deliverybewijs zijn groen.\n",
  );
}

if (
  process.argv[1]
  && import.meta.url
    === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error
        ? error.message
        : "SENDGRID_STAGING_ACCEPTANCE_FAILED"}\n`,
    );
    process.exitCode = 1;
  });
}
