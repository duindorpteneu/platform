import {
  createHash,
  createHmac,
  createPublicKey,
  randomBytes,
  randomUUID,
} from "node:crypto";
import { spawnSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { createServerClient } from "@supabase/ssr";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { ImapFlow } from "imapflow";
import { requireExplicitDatabaseTls } from "../staging/require-database-tls.mjs";

const allowedApiBases = new Set([
  "https://api.sendgrid.com",
  "https://api.eu.sendgrid.com",
]);
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const releasePattern = /^[a-f0-9]{40}$/u;
const runMarkerPattern = /^[0-9]{1,20}-[0-9]{1,6}$/u;
const stagingProjectRef = "dxbdjtbyghsovlrdcwcr";
const acceptanceProfileName = "Staging SendGrid-acceptatie";
const acceptanceAuthMarker = "duindorp-sendgrid-acceptance-v1";
const acceptanceEmailPattern = /^staging-sendgrid-[0-9]{1,20}-[0-9]{1,6}@example\.invalid$/u;
const postgresImage = "public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453";
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

function acceptanceUserId(runMarker) {
  if (!runMarkerPattern.test(runMarker)) {
    throw new Error("SENDGRID_ACCEPTANCE_RUN_ID_INVALID");
  }
  const bytes = createHash("sha256")
    .update(`duindorp-sendgrid-acceptance:${runMarker}`)
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function validateFixtureConfig(values) {
  const fixture = {
    supabaseUrl: required(values, "NEXT_PUBLIC_SUPABASE_URL"),
    supabaseAnonKey:
      values.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim() ?? "",
    serviceRoleKey: required(values, "SUPABASE_SERVICE_ROLE_KEY"),
    databaseUrl: requireExplicitDatabaseTls(
      required(values, "SUPABASE_DB_URL"),
    ),
    projectRef: required(values, "SUPABASE_PROJECT_REF"),
    runMarker:
      values.SENDGRID_ACCEPTANCE_RUN_ID?.trim() ?? "",
  };
  let supabaseUrl;
  let databaseUrl;
  try {
    supabaseUrl = new URL(fixture.supabaseUrl);
    databaseUrl = new URL(fixture.databaseUrl);
  } catch {
    throw new Error("SENDGRID_ACCEPTANCE_FIXTURE_URL_INVALID");
  }
  const username = decodeURIComponent(databaseUrl.username);
  const directTarget = databaseUrl.hostname
      === `db.${stagingProjectRef}.supabase.co`
    && username === "postgres"
    && (databaseUrl.port === "" || databaseUrl.port === "5432");
  const poolerTarget = databaseUrl.hostname.endsWith(
    ".pooler.supabase.com",
  )
    && username === `postgres.${stagingProjectRef}`
    && ["5432", "6543"].includes(databaseUrl.port);
  const parameters = [...new Set(databaseUrl.searchParams.keys())];
  const connectTimeout = databaseUrl.searchParams.get("connect_timeout");
  if (
    fixture.projectRef !== stagingProjectRef
    || supabaseUrl.href
      !== `https://${stagingProjectRef}.supabase.co/`
    || !["postgres:", "postgresql:"].includes(databaseUrl.protocol)
    || !databaseUrl.password
    || databaseUrl.pathname !== "/postgres"
    || (!directTarget && !poolerTarget)
    || parameters.some(
      (parameter) => !["connect_timeout", "sslmode"].includes(parameter),
    )
    || parameters.some(
      (parameter) => databaseUrl.searchParams.getAll(parameter).length !== 1,
    )
    || !["require", "verify-ca", "verify-full"].includes(
      databaseUrl.searchParams.get("sslmode"),
    )
    || (connectTimeout !== null && (
      !/^[1-9][0-9]{0,2}$/u.test(connectTimeout)
      || Number(connectTimeout) > 120
    ))
    || fixture.serviceRoleKey.length < 40
    || (fixture.supabaseAnonKey
      && fixture.supabaseAnonKey.length < 20)
    || !runMarkerPattern.test(fixture.runMarker)
  ) {
    throw new Error("SENDGRID_ACCEPTANCE_FIXTURE_CONFIG_INVALID");
  }
  return {
    ...fixture,
    supabaseUrl: supabaseUrl.toString(),
    databaseUrl: databaseUrl.toString(),
  };
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
  const fixture = validateFixtureConfig(values);
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
    ...fixture,
    imapHost: required(values, "E2E_MAILBOX_IMAP_HOST"),
    imapPort: Number(required(values, "E2E_MAILBOX_IMAP_PORT")),
    imapUser: required(values, "E2E_MAILBOX_IMAP_USER"),
    imapPassword: required(values, "E2E_MAILBOX_IMAP_PASSWORD"),
    imapMailbox:
      values.E2E_MAILBOX_IMAP_MAILBOX?.trim() || "INBOX",
  };
  let webhookUrl;
  let stagingBaseUrl;
  try {
    webhookUrl = new URL(config.webhookUrl);
    stagingBaseUrl = new URL(config.stagingBaseUrl);
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
    || !scopes.scopes.includes("mail.send")
  ) {
    throw new Error("SENDGRID_MAIL_SEND_SCOPE_MISSING");
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
    if (index < 0) throw new Error("E2E_TOTP_SECRET_INVALID");
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

function supabaseOptions() {
  return {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    global: {
      fetch: (input, init = {}) => fetch(input, {
        ...init,
        signal: init.signal
          ? AbortSignal.any([
            init.signal,
            AbortSignal.timeout(20_000),
          ])
          : AbortSignal.timeout(20_000),
      }),
    },
  };
}

function runAcceptanceSql(
  config,
  statement,
  errorCode,
  dependencies = {},
) {
  const spawn = dependencies.spawnSync ?? spawnSync;
  const result = spawn("docker", [
    "run",
    "--rm",
    "--interactive",
    "--read-only",
    "--cap-drop=ALL",
    "--security-opt",
    "no-new-privileges:true",
    "--tmpfs",
    "/tmp:rw,noexec,nosuid,size=16m",
    "--env",
    "TARGET_DB_URL",
    "--entrypoint",
    "sh",
    postgresImage,
    "-ceu",
    "psql \"$TARGET_DB_URL\" --no-psqlrc --set=ON_ERROR_STOP=1",
  ], {
    env: {
      ...process.env,
      TARGET_DB_URL: config.databaseUrl,
    },
    input: statement,
    encoding: "utf8",
    stdio: ["pipe", "ignore", "ignore"],
    timeout: 45_000,
  });
  if (result.status !== 0) throw new Error(errorCode);
}

function activateAcceptanceProfile(
  config,
  userId,
  dependencies = {},
) {
  const statement = `
do $fixture$
declare
  target app.staff_profiles%rowtype;
begin
  perform set_config('app.staff_automation_internal', 'on', true);

  select * into target
  from app.staff_profiles
  where auth_user_id = '${userId}'::uuid
  for update;

  if found and (
    target.display_name <> '${acceptanceProfileName}'
    or target.role <> 'beheerder'::app.staff_role
    or target.automation_kind is distinct from 'sendgrid_acceptance'
  ) then
    raise exception 'SENDGRID_ACCEPTANCE_PROFILE_COLLISION';
  end if;

  if found then
    update app.staff_profiles
    set active = true
    where auth_user_id = '${userId}'::uuid;
  else
    insert into app.staff_profiles(
      auth_user_id, display_name, role, active, automation_kind
    ) values (
      '${userId}'::uuid,
      '${acceptanceProfileName}',
      'beheerder'::app.staff_role,
      true,
      'sendgrid_acceptance'
    );
  end if;

  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    '${userId}'::uuid,
    'staff.acceptance.activated',
    'staff_profile',
    (select id from app.staff_profiles
     where auth_user_id = '${userId}'::uuid),
    jsonb_build_object('provider', 'sendgrid')
  );
end;
$fixture$;
`;
  runAcceptanceSql(
    config,
    statement,
    "SENDGRID_ACCEPTANCE_PROFILE_ACTIVATION_FAILED",
    dependencies,
  );
}

function deactivateAllAcceptanceProfiles(
  config,
  dependencies = {},
) {
  const statement = `
do $fixture$
declare
  target app.staff_profiles%rowtype;
  now_utc timestamptz := timezone('utc', now());
  sessions_revoked integer;
  exchanges_consumed integer;
  scan_grants_revoked integer;
begin
  perform set_config('app.staff_automation_internal', 'on', true);

  for target in
    select profile.*
    from app.staff_profiles profile
    where profile.automation_kind = 'sendgrid_acceptance'
    for update
  loop
    sessions_revoked := 0;
    exchanges_consumed := 0;
    scan_grants_revoked := 0;

    update app.staff_profiles
    set active = false
    where auth_user_id = target.auth_user_id
      and active;

    perform set_config('app.qr_internal', 'on', true);
    update private.qr_scan_grants grant_row
    set revoked_at = now_utc,
        revocation_reason = 'Staging SendGrid-acceptatie beëindigd'
    where grant_row.staff_session_hash in (
      select session.token_hash
      from private.staff_sessions session
      where session.auth_user_id = target.auth_user_id
    )
      and grant_row.consumed_at is null
      and grant_row.revoked_at is null;
    get diagnostics scan_grants_revoked = row_count;
    perform set_config('app.qr_internal', 'off', true);

    update private.staff_sessions session
    set revoked_at = now_utc
    where session.auth_user_id = target.auth_user_id
      and session.revoked_at is null;
    get diagnostics sessions_revoked = row_count;

    update private.staff_session_exchanges exchange
    set consumed_at = now_utc
    where exchange.auth_user_id = target.auth_user_id
      and exchange.consumed_at is null;
    get diagnostics exchanges_consumed = row_count;

    if target.active
      or sessions_revoked > 0
      or exchanges_consumed > 0
      or scan_grants_revoked > 0
    then
      insert into app.audit_logs(
        actor_user_id, action, entity_type, entity_id, metadata
      ) values (
        target.auth_user_id,
        'staff.acceptance.deactivated',
        'staff_profile',
        target.id,
        jsonb_build_object(
          'provider', 'sendgrid',
          'sessionsRevoked', sessions_revoked,
          'exchangesConsumed', exchanges_consumed,
          'scanGrantsRevoked', scan_grants_revoked
        )
      );
    end if;
  end loop;
end;
$fixture$;

-- This assertion deliberately runs as a second transaction. A collision makes
-- the workflow fail closed, while the credential cleanup above stays committed.
do $assertion$
begin
  if exists (
    select 1
    from app.staff_profiles profile
    left join auth.users auth_user
      on auth_user.id = profile.auth_user_id
    where profile.automation_kind = 'sendgrid_acceptance'
      and (
        profile.display_name <> '${acceptanceProfileName}'
        or
        profile.role <> 'beheerder'::app.staff_role
        or (
          auth_user.id is not null
          and coalesce(
            auth_user.raw_app_meta_data->>'duindorp_acceptance',
            ''
          ) <> '${acceptanceAuthMarker}'
        )
      )
  ) then
    raise exception 'SENDGRID_ACCEPTANCE_PROFILE_COLLISION';
  end if;
end;
$assertion$;
`;
  runAcceptanceSql(
    config,
    statement,
    "SENDGRID_ACCEPTANCE_PROFILE_DEACTIVATION_FAILED",
    dependencies,
  );
}

function createFixtureAdmin(config, dependencies = {}) {
  const createClient = dependencies.createAdminClient
    ?? createSupabaseClient;
  return createClient(
    config.supabaseUrl,
    config.serviceRoleKey,
    supabaseOptions(),
  );
}

async function findAcceptanceAuthUser(admin, userId) {
  const result = await admin.auth.admin.getUserById(
    userId,
  );
  if (result.error) {
    if (result.error.status === 404) return null;
    throw new Error("SENDGRID_ACCEPTANCE_AUTH_LOOKUP_FAILED");
  }
  return result.data.user ?? null;
}

function assertAcceptanceAuthUser(user, userId) {
  if (
    user.id !== userId
    || user.app_metadata?.duindorp_acceptance
      !== acceptanceAuthMarker
    || !acceptanceEmailPattern.test(user.email ?? "")
  ) {
    throw new Error("SENDGRID_ACCEPTANCE_AUTH_COLLISION");
  }
}

async function listAcceptanceAuthUsers(admin) {
  const users = [];
  for (let page = 1; page <= 10; page += 1) {
    const listed = await admin.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (listed.error) {
      throw new Error("SENDGRID_ACCEPTANCE_AUTH_LIST_FAILED");
    }
    for (const user of listed.data.users) {
      if (
        user.app_metadata?.duindorp_acceptance
          === acceptanceAuthMarker
        && acceptanceEmailPattern.test(user.email ?? "")
      ) {
        users.push(user);
      }
    }
    if (listed.data.users.length < 1000) break;
  }
  return users;
}

export async function cleanupSendGridAcceptanceFixture(
  values,
  dependencies = {},
) {
  const config = values.databaseUrl
    ? values
    : validateFixtureConfig(values);
  const admin = createFixtureAdmin(config, dependencies);
  const currentUserId = acceptanceUserId(config.runMarker);
  const errors = [];
  let users = [];
  let currentIdentityBlocked = false;
  try {
    users = await listAcceptanceAuthUsers(admin);
  } catch (error) {
    errors.push(error);
  }

  const usersById = new Map(
    users.map((user) => [user.id, user]),
  );
  if (!usersById.has(currentUserId)) {
    try {
      const currentUser = await findAcceptanceAuthUser(
        admin,
        currentUserId,
      );
      if (currentUser) {
        assertAcceptanceAuthUser(currentUser, currentUserId);
        usersById.set(currentUserId, currentUser);
      }
    } catch (error) {
      errors.push(error);
      currentIdentityBlocked = error instanceof Error
        && error.message === "SENDGRID_ACCEPTANCE_AUTH_COLLISION";
    }
  }
  // Always attempt to deactivate the current run profile, including failures
  // that happened between profile creation and Auth visibility.
  const cleanupUserIds = new Set(usersById.keys());
  if (!currentIdentityBlocked) cleanupUserIds.add(currentUserId);

  // Each layer is attempted independently. The database sweep also closes
  // profiles whose Auth user disappeared during an earlier partial cleanup.
  try {
    deactivateAllAcceptanceProfiles(config, dependencies);
  } catch (error) {
    errors.push(error);
  }
  for (const userId of cleanupUserIds) {
    if (
      userId === currentUserId
      && dependencies.accessToken
    ) {
      try {
        const signedOut = await admin.auth.admin.signOut(
          dependencies.accessToken,
          "global",
        );
        if (signedOut.error) {
          throw new Error(
            "SENDGRID_ACCEPTANCE_GLOBAL_SIGNOUT_FAILED",
          );
        }
      } catch (error) {
        errors.push(error);
      }
    }
    if (usersById.has(userId)) {
      try {
        const deleted = await admin.auth.admin.deleteUser(
          userId,
          false,
        );
        if (deleted.error) {
          throw new Error("SENDGRID_ACCEPTANCE_AUTH_DELETE_FAILED");
        }
      } catch (error) {
        errors.push(error);
      }
    }
  }
  if (errors.length > 0) {
    throw new AggregateError(
      errors,
      "SENDGRID_ACCEPTANCE_FIXTURE_CLEANUP_FAILED",
    );
  }
}

export async function createSendGridAcceptanceFixture(
  config,
  dependencies = {},
) {
  await cleanupSendGridAcceptanceFixture(config, dependencies);
  const admin = createFixtureAdmin(config, dependencies);
  const random = dependencies.randomBytes ?? randomBytes;
  const userId = acceptanceUserId(config.runMarker);
  const email = `staging-sendgrid-${config.runMarker}@example.invalid`;
  const password = `${random(32).toString("base64url")}!Aa1`;
  if (!acceptanceEmailPattern.test(email) || password.length < 32) {
    throw new Error("SENDGRID_ACCEPTANCE_AUTH_INPUT_INVALID");
  }
  const created = await admin.auth.admin.createUser({
    id: userId,
    email,
    password,
    email_confirm: true,
    app_metadata: {
      duindorp_acceptance: acceptanceAuthMarker,
    },
  });
  if (created.error || !created.data.user) {
    throw new Error("SENDGRID_ACCEPTANCE_AUTH_CREATE_FAILED");
  }
  assertAcceptanceAuthUser(created.data.user, userId);
  activateAcceptanceProfile(
    config,
    userId,
    dependencies,
  );
  return { email, password };
}

export async function createAal2AdminSession(
  config,
  credentials,
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
    email: credentials.email,
    password: credentials.password,
  });
  if (signedIn.error || !signedIn.data.session) {
    throw new Error("E2E_ADMIN_SIGN_IN_FAILED");
  }
  const factors = await client.auth.mfa.listFactors();
  if (
    factors.error
    || (factors.data?.totp?.length ?? 0) !== 0
  ) {
    throw new Error("E2E_ADMIN_MFA_FACTOR_INVALID");
  }
  const enrolled = await client.auth.mfa.enroll({
    factorType: "totp",
    friendlyName: "SendGrid staging acceptance",
  });
  const factorId = enrolled.data?.id;
  const secret = enrolled.data?.totp?.secret
    ?.replaceAll(/\s/gu, "")
    .toUpperCase();
  if (
    enrolled.error
    || !factorId
    || !secret
    || !/^[A-Z2-7]{16,128}$/u.test(secret)
  ) {
    throw new Error("E2E_ADMIN_MFA_ENROLL_FAILED");
  }
  const verified = await client.auth.mfa.challengeAndVerify({
    factorId,
    code: currentTotp(
      secret,
      dependencies.now?.() ?? Date.now(),
    ),
  });
  if (verified.error) {
    throw new Error("E2E_ADMIN_MFA_VERIFY_FAILED");
  }
  const aal = await client.auth.mfa.getAuthenticatorAssuranceLevel();
  if (
    aal.error
    || aal.data.currentLevel !== "aal2"
    || aal.data.nextLevel !== "aal2"
  ) {
    throw new Error("E2E_ADMIN_MFA_POLICY_INVALID");
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
  return {
    client,
    cookies,
    accessToken: session.data.session.access_token,
  };
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
  let session;
  let acceptanceError;
  try {
    const credentials = await createSendGridAcceptanceFixture(
      config,
      dependencies,
    );
    session = await createAal2AdminSession(
      config,
      credentials,
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
        ephemeral_admin_cleanup: true,
        ephemeral_admin_mfa: true,
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
  } catch (error) {
    acceptanceError = error;
    throw error;
  } finally {
    await session?.client.auth.signOut({ scope: "local" })
      .catch(() => undefined);
    try {
      await cleanupSendGridAcceptanceFixture(config, {
        ...dependencies,
        accessToken: session?.accessToken,
      });
    } catch (cleanupError) {
      if (!acceptanceError) throw cleanupError;
      throw new AggregateError(
        [acceptanceError, cleanupError],
        "SENDGRID_ACCEPTANCE_AND_CLEANUP_FAILED",
      );
    }
  }
}

async function main() {
  if (process.env.CLEANUP_ONLY === "1") {
    await cleanupSendGridAcceptanceFixture(process.env);
    process.stdout.write(
      "Tijdelijke SendGrid-acceptatiemedewerker is inactief en verwijderd.\n",
    );
    return;
  }
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
    "SendGrid appkey, tijdelijke beheerder-MFA, idempotente app-testdelivery, exact één inboxbericht, gekoppeld signed deliverybewijs en cleanup zijn groen.\n",
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
