import assert from "node:assert/strict";
import crypto from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import net from "node:net";
import { chromium } from "@playwright/test";
import { createBrowserClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import {
  assertKeyboardFocusVisible,
  assertNoAutomatedA11yViolations,
} from "./browser-a11y.mjs";

const host = "localhost";
const port = 3101;
const baseUrl = `http://${host}:${port}`;
const fixtureEmail = "parent-access-browser@example.invalid";
const staffEmail = "parent-access-browser-staff@example.invalid";
const staffDisplayName = "Browser portaalbeheer";
const seasonId = "ab100000-0000-4000-8000-000000000001";
const memberIds = [
  "ab200000-0000-4000-8000-000000000001",
  "ab200000-0000-4000-8000-000000000002",
];
const memberSeasonIds = [
  "ab300000-0000-4000-8000-000000000001",
  "ab300000-0000-4000-8000-000000000002",
];
const parentPepper = "parent-access-browser-pepper-2026-with-safe-length";

function localSupabaseEnv() {
  const output = execFileSync(
    "pnpm",
    ["exec", "supabase", "status", "-o", "env"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  );
  return Object.fromEntries(
    output
      .split(/\r?\n/)
      .filter((line) => line.includes("="))
      .map((line) => {
        const separator = line.indexOf("=");
        return [
          line.slice(0, separator),
          line.slice(separator + 1).replace(/^["']|["']$/g, ""),
        ];
      }),
  );
}

function runSql(databaseUrl, sql) {
  execFileSync(
    "psql",
    [databaseUrl, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
    { stdio: "ignore" },
  );
}

function queryScalar(databaseUrl, sql) {
  return execFileSync(
    "psql",
    [databaseUrl, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  ).trim();
}

function setActiveSeason(databaseUrl, targetSeasonId) {
  if (targetSeasonId && /^[0-9a-f-]{36}$/.test(targetSeasonId)) {
    runSql(
      databaseUrl,
      `update app.app_settings set active_season_id = '${targetSeasonId}'::uuid where id = true;`,
    );
    return;
  }
  runSql(
    databaseUrl,
    "update app.app_settings set active_season_id = null where id = true;",
  );
}

function cleanupSql() {
  const memberList = memberIds.map((id) => `'${id}'::uuid`).join(", ");
  const memberSeasonList = memberSeasonIds
    .map((id) => `'${id}'::uuid`)
    .join(", ");
  return `
    delete from app.email_events
    where email_job_id in (
      select job.id
      from private.email_jobs job
      where job.parent_access_batch_id in (
        select batch.id
        from private.parent_access_batches batch
        where batch.actor_user_id in (
          select profile.auth_user_id
          from app.staff_profiles profile
          where profile.display_name = '${staffDisplayName}'
        )
      )
    );
    delete from private.email_jobs
    where parent_access_batch_id in (
      select batch.id
      from private.parent_access_batches batch
      where batch.actor_user_id in (
        select profile.auth_user_id
        from app.staff_profiles profile
        where profile.display_name = '${staffDisplayName}'
      )
    );
    delete from private.parent_access_batch_items
    where batch_id in (
      select batch.id
      from private.parent_access_batches batch
      where batch.actor_user_id in (
        select profile.auth_user_id
        from app.staff_profiles profile
        where profile.display_name = '${staffDisplayName}'
      )
    );
    delete from private.parent_access_batches
    where actor_user_id in (
      select profile.auth_user_id
      from app.staff_profiles profile
      where profile.display_name = '${staffDisplayName}'
    );
    delete from app.audit_logs
    where actor_user_id in (
      select profile.auth_user_id
      from app.staff_profiles profile
      where profile.display_name = '${staffDisplayName}'
    )
      or entity_id in (${memberList}, ${memberSeasonList});
    delete from private.parent_portal_grants
    where member_season_id in (${memberSeasonList});
    delete from private.parent_otp_challenges
    where parent_account_id in (
      select account.id
      from private.parent_accounts account
      where account.email_normalized = '${fixtureEmail}'
    );
    delete from private.parent_sessions
    where parent_account_id in (
      select account.id
      from private.parent_accounts account
      where account.email_normalized = '${fixtureEmail}'
    );
    delete from private.parent_member_links
    where member_id in (${memberList});
    delete from private.parent_accounts
    where email_normalized = '${fixtureEmail}';
    delete from app.member_seasons
    where id in (${memberSeasonList});
    delete from app.members
    where id in (${memberList});
    delete from app.inventory_settings
    where season_id = '${seasonId}'::uuid;
    delete from app.seasons
    where id = '${seasonId}'::uuid;
    delete from private.staff_sessions
    where auth_user_id in (
      select profile.auth_user_id
      from app.staff_profiles profile
      where profile.display_name = '${staffDisplayName}'
    );
    delete from app.staff_profiles
    where display_name = '${staffDisplayName}';
  `;
}

function fixtureSql(userId) {
  return `
    insert into app.staff_profiles(auth_user_id, display_name, role)
    values ('${userId}'::uuid, '${staffDisplayName}', 'beheerder');
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      metadata
    ) values (
      '${userId}'::uuid,
      'acceptance.privacy_uuid_canary',
      'acceptance_test',
      jsonb_build_object(
        'opaqueId',
        'ada00000-0000-4000-8000-000000000000'
      )
    );
    insert into app.seasons(
      id,
      name,
      starts_on,
      ends_on,
      default_amount_cents,
      status,
      opened_at
    ) values (
      '${seasonId}'::uuid,
      'Browser portaaltoegang 2048/2049',
      '2048-07-01',
      '2049-06-30',
      12500,
      'open',
      timezone('utc', now())
    );
    update app.app_settings
    set active_season_id = null
    where id = true;
    insert into app.members(
      id,
      relation_number,
      first_name,
      last_name,
      email,
      team,
      active_for_season,
      gender
    ) values
      (
        '${memberIds[0]}'::uuid,
        'PAB-001',
        'Ada',
        'Toegang',
        '${fixtureEmail}',
        'JO-PAB',
        true,
        'female'
      ),
      (
        '${memberIds[1]}'::uuid,
        'PAB-002',
        'Ben',
        'Toegang',
        ' PARENT-ACCESS-BROWSER@example.invalid ',
        'JO-PAB',
        true,
        'male'
      );
    insert into app.member_seasons(
      id,
      member_id,
      season_id,
      team_name,
      participation_status,
      reconciliation_status
    ) values
      (
        '${memberSeasonIds[0]}'::uuid,
        '${memberIds[0]}'::uuid,
        '${seasonId}'::uuid,
        'JO-PAB',
        'active',
        'resolved'
      ),
      (
        '${memberSeasonIds[1]}'::uuid,
        '${memberIds[1]}'::uuid,
        '${seasonId}'::uuid,
        'JO-PAB',
        'active',
        'resolved'
      );
    update private.member_sensitive_identity
    set date_of_birth = case member_id
      when '${memberIds[0]}'::uuid then date '2014-01-02'
      else date '2012-03-04'
    end
    where member_id in (
      '${memberIds[0]}'::uuid,
      '${memberIds[1]}'::uuid
    );
    update app.app_settings
    set active_season_id = '${seasonId}'::uuid
    where id = true;
  `;
}

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.replace(/=+$/, "").toUpperCase()) {
    const position = alphabet.indexOf(character);
    if (position < 0) throw new Error("PARENT_ACCESS_BROWSER_TOTP_INVALID");
    bits += position.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let index = 0; index + 8 <= bits.length; index += 8) {
    bytes.push(Number.parseInt(bits.slice(index, index + 8), 2));
  }
  return Buffer.from(bytes);
}

function currentTotp(secret) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30_000)));
  const digest = crypto
    .createHmac("sha1", decodeBase32(secret))
    .update(counter)
    .digest();
  const offset = digest[digest.length - 1] & 15;
  return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000)
    .toString()
    .padStart(6, "0");
}

function portIsAvailable() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => server.close(() => resolve(true)));
    server.listen(port, host);
  });
}

async function waitForApp(appProcess) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (appProcess.exitCode !== null) {
      throw new Error("PARENT_ACCESS_BROWSER_APP_EXITED");
    }
    try {
      const response = await fetch(`${baseUrl}/staff/login`, {
        redirect: "manual",
        signal: AbortSignal.timeout(2_000),
      });
      if (response.status === 200) return;
    } catch {
      // De eigen testserver start nog.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("PARENT_ACCESS_BROWSER_APP_TIMEOUT");
}

async function stopApp(appProcess) {
  if (!appProcess || appProcess.exitCode !== null) return;
  const exited = new Promise((resolve) => appProcess.once("exit", resolve));
  try {
    process.kill(-appProcess.pid, "SIGTERM");
  } catch {
    appProcess.kill("SIGTERM");
  }
  await Promise.race([
    exited,
    new Promise((resolve) => setTimeout(resolve, 5_000)),
  ]);
}

function assertResponseShape(payload, expected) {
  for (const [key, value] of Object.entries(expected)) {
    assert.equal(payload?.[key], value, `PARENT_ACCESS_BROWSER_${key.toUpperCase()}`);
  }
}

const local = localSupabaseEnv();
for (const name of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY"]) {
  if (!local[name]) throw new Error(`PARENT_ACCESS_BROWSER_MISSING_${name}`);
}
if (!(await portIsAvailable())) {
  throw new Error("PARENT_ACCESS_BROWSER_PORT_OCCUPIED");
}

let previousActiveSeason = queryScalar(
  local.DB_URL,
  "select coalesce(active_season_id::text, '') from app.app_settings where id = true;",
);
if (previousActiveSeason === seasonId) {
  previousActiveSeason = queryScalar(
    local.DB_URL,
    `select coalesce((
      select id::text
      from app.seasons
      where id <> '${seasonId}'::uuid
      order by starts_on desc nulls last, id
      limit 1
    ), '');`,
  );
}
setActiveSeason(local.DB_URL, previousActiveSeason);
runSql(local.DB_URL, cleanupSql());

const admin = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
});
const existingUsers = await admin.auth.admin.listUsers();
if (existingUsers.error) {
  throw new Error("PARENT_ACCESS_BROWSER_AUTH_LIST_FAILED");
}
for (const user of existingUsers.data.users) {
  if (user.email === staffEmail) {
    const deleted = await admin.auth.admin.deleteUser(user.id);
    if (deleted.error) throw new Error("PARENT_ACCESS_BROWSER_STALE_AUTH_DELETE_FAILED");
  }
}

const password = `Pa-${crypto.randomBytes(18).toString("base64url")}!9aA`;
let userId;
let appProcess;
let browser;
try {
  const created = await admin.auth.admin.createUser({
    email: staffEmail,
    password,
    email_confirm: true,
  });
  if (created.error || !created.data.user) {
    throw new Error("PARENT_ACCESS_BROWSER_AUTH_CREATE_FAILED");
  }
  userId = created.data.user.id;
  assert.match(userId, /^[0-9a-f-]{36}$/);
  runSql(local.DB_URL, fixtureSql(userId));

  appProcess = spawn(
    "pnpm",
    ["start", "--hostname", host, "--port", String(port)],
    {
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        APP_BASE_URL: baseUrl,
        NEXT_PUBLIC_SUPABASE_URL: local.API_URL,
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: local.ANON_KEY,
        SUPABASE_SECRET_KEY: local.SERVICE_ROLE_KEY,
        PARENT_TOKEN_PEPPER: parentPepper,
        EMAIL_ENABLED: "false",
        MOLLIE_ENABLED: "false",
        SENDGRID_API_KEY: "",
        SENDGRID_FROM_EMAIL: "",
        SENDGRID_REPLY_TO_EMAIL: "",
        SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "",
        MOLLIE_API_KEY: "",
      },
    },
  );
  await waitForApp(appProcess);

  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();
  const localAuthCookies = new Map();
  const localMfaClient = createBrowserClient(local.API_URL, local.ANON_KEY, {
    isSingleton: false,
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    cookies: {
      getAll: () => [...localAuthCookies.entries()].map(([name, cookie]) => ({
        name,
        value: cookie.value,
      })),
      setAll: (cookies) => {
        for (const cookie of cookies) {
          if (!cookie.value || cookie.options?.maxAge === 0) {
            localAuthCookies.delete(cookie.name);
          } else {
            localAuthCookies.set(cookie.name, cookie);
          }
        }
      },
    },
  });
  const localSignIn = await localMfaClient.auth.signInWithPassword({
    email: staffEmail,
    password,
  });
  if (localSignIn.error || !localSignIn.data.session) {
    throw new Error("PARENT_ACCESS_BROWSER_AAL2_SIGN_IN_FAILED");
  }
  const localEnrollment = await localMfaClient.auth.mfa.enroll({
    factorType: "totp",
    friendlyName: "Portaaltoegang browsertest",
    issuer: "Duindorp SV",
  });
  if (localEnrollment.error || !localEnrollment.data) {
    throw new Error("PARENT_ACCESS_BROWSER_AAL2_ENROLLMENT_FAILED");
  }
  const localVerification = await localMfaClient.auth.mfa.challengeAndVerify({
    factorId: localEnrollment.data.id,
    code: currentTotp(localEnrollment.data.totp.secret),
  });
  if (localVerification.error) {
    throw new Error("PARENT_ACCESS_BROWSER_AAL2_VERIFICATION_FAILED");
  }
  const localSession = await localMfaClient.auth.getSession();
  const localAccessToken = localSession.data.session?.access_token;
  if (localSession.error || !localAccessToken) {
    throw new Error("PARENT_ACCESS_BROWSER_AAL2_SESSION_MISSING");
  }
  const browserAuthCookies = [...localAuthCookies.values()].map((cookie) => ({
    name: cookie.name,
    value: cookie.value,
    url: baseUrl,
    sameSite: "Lax",
  }));
  if (browserAuthCookies.length === 0) {
    throw new Error("PARENT_ACCESS_BROWSER_AAL2_COOKIE_MISSING");
  }
  await context.addCookies(browserAuthCookies);
  await page.goto(`${baseUrl}/staff/login`);
  const localAppSession = await page.evaluate(async (accessToken) => {
    const response = await fetch("/api/staff-auth/session", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Duindorp-CSRF": "same-origin",
      },
      body: JSON.stringify({ accessToken }),
    });
    const payload = await response.json().catch(() => null);
    return {
      status: response.status,
      landingPath: payload?.landingPath ?? null,
    };
  }, localAccessToken);
  if (
    localAppSession.status !== 200
    || localAppSession.landingPath !== "/backoffice"
  ) {
    throw new Error("PARENT_ACCESS_BROWSER_APP_SESSION_FAILED");
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`${baseUrl}/backoffice`);
  await page.waitForURL(`${baseUrl}/backoffice`);

  for (const [path, heading, label] of [
    ["/backoffice/pakketten", "Kledingpakketten", "packages"],
    ["/backoffice/actiepunten", "Actiepunten", "action_items"],
    ["/backoffice/leden", "Leden", "members"],
    ["/backoffice/leveringen", "Leveringen", "deliveries"],
    ["/backoffice/emails", "E-mailcentrum", "email"],
  ]) {
    const response = await page.goto(`${baseUrl}${path}`, {
      waitUntil: "domcontentloaded",
    });
    assert.equal(response?.ok(), true, `${label}: HTTP niet groen`);
    await page.getByRole("heading", { name: heading, exact: true }).waitFor();
    await assertNoAutomatedA11yViolations(
      page,
      `parent_access_phase_b_${label}`,
    );
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await localMfaClient.auth.signOut({ scope: "local" });

  await page.goto(`${baseUrl}/backoffice/portaaltoegang`);
  await page
    .getByRole("heading", { name: "Portaaltoegang", exact: true })
    .waitFor();
  await page.getByText("Beheerder · MFA", { exact: true }).waitFor();
  const initialBody = await page.locator("body").innerText();
  assert.equal(initialBody.includes(fixtureEmail), false);

  await page.getByLabel("Zoeken").fill("PAB-");
  const queryResponsePromise = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return response.request().method() === "POST"
      && url.pathname === "/api/portal-access/query";
  });
  await page.getByRole("button", { name: "Zoeken" }).click();
  const queryResponse = await queryResponsePromise;
  assert.equal(queryResponse.ok(), true);
  const queryUrl = new URL(queryResponse.url());
  assert.equal(queryUrl.search, "");
  assert.deepEqual(
    JSON.parse(queryResponse.request().postData() ?? "{}"),
    {
      seasonId,
      search: "PAB-",
      offset: 0,
      limit: 50,
    },
  );
  assert.match(
    queryResponse.headers()["cache-control"] ?? "",
    /no-store.*private|private.*no-store/,
  );
  const queryPayload = await queryResponse.json();
  assert.equal(JSON.stringify(queryPayload).includes(fixtureEmail), false);
  assert.equal(queryPayload.members.length, 2);
  assert.equal(
    queryPayload.members.every(
      (member) => member.emailMasked === "p***@example.invalid"
        && member.sharedEmailMemberCount === 2,
    ),
    true,
  );
  await page.getByText("Gedeeld door 2 leden", { exact: true }).first().waitFor();
  await assertNoAutomatedA11yViolations(page, "parent_access_selection");
  await assertKeyboardFocusVisible(page, "parent_access_selection");

  await page.getByLabel("Selecteer Ada Toegang").check();
  await page.getByLabel("Selecteer Ben Toegang").check();
  const preflightResponsePromise = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return response.request().method() === "POST"
      && url.pathname === "/api/portal-access/preflight";
  });
  await page.getByRole("button", { name: "Controleer selectie" }).click();
  const preflightResponse = await preflightResponsePromise;
  assert.equal(preflightResponse.ok(), true);
  const preflight = await preflightResponse.json();
  assertResponseShape(preflight, {
    operation: "activate",
    selectionCount: 2,
    eligibleCount: 2,
    unchangedCount: 0,
    blockedCount: 0,
  });
  assert.equal(preflight.groups.length, 1);
  assert.equal(preflight.groups[0].members.length, 2);
  assert.equal(preflight.groups[0].invitationRequired, true);
  assert.ok(preflight.mailPreview?.subject);
  assert.ok(preflight.mailPreview?.text);
  assert.ok(preflight.mailPreview?.templateVersion > 0);
  const previewText = JSON.stringify(preflight.mailPreview);
  assert.match(previewText, /\/login/);
  assert.equal(
    /\b\d{6}\b|[?&#](?:token|code)=|Ada|Ben|parent-access-browser@/i.test(previewText),
    false,
  );

  const activateResponsePromise = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return response.request().method() === "POST"
      && url.pathname === "/api/portal-access/activate";
  });
  await page.getByRole("button", { name: "Definitief activeren" }).click();
  const activateResponse = await activateResponsePromise;
  assert.equal(activateResponse.ok(), true);
  assertResponseShape(await activateResponse.json(), {
    operation: "activate",
    selectedCount: 2,
    changedCount: 2,
    unchangedCount: 0,
    groupCount: 1,
    inviteJobCount: 1,
    committed: true,
    reused: false,
  });
  await page
    .getByText("2 toegang(en) bijgewerkt · 1 uitnodiging(en) klaargezet.", {
      exact: true,
    })
    .waitFor();
  for (const name of ["Ada Toegang", "Ben Toegang"]) {
    const rowText = await page
      .getByRole("row")
      .filter({ hasText: name })
      .innerText();
    assert.match(rowText, /Actief/);
  }

  await page.getByRole("button", { name: "Intrekken" }).click();
  await page.getByLabel("Selecteer Ada Toegang").check();
  await page.getByLabel("Reden voor intrekken").fill(
    "Browseracceptatie intrekking",
  );
  const revokePreviewPromise = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return response.request().method() === "POST"
      && url.pathname === "/api/portal-access/preflight";
  });
  await page.getByRole("button", { name: "Controleer selectie" }).click();
  const revokePreviewResponse = await revokePreviewPromise;
  assert.equal(revokePreviewResponse.ok(), true);
  const revokePreview = await revokePreviewResponse.json();
  assertResponseShape(revokePreview, {
    operation: "revoke",
    selectionCount: 1,
    eligibleCount: 1,
    unchangedCount: 0,
    blockedCount: 0,
  });
  assert.equal(revokePreview.groups.length, 1);
  assert.equal(revokePreview.groups[0].nonSelectedCount, 1);
  assert.equal(revokePreview.mailPreview, null);
  await page
    .getByText(/1 ander\(e\) lid\/leden met dit adres behouden toegang/)
    .waitFor();

  const revokeResponsePromise = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return response.request().method() === "POST"
      && url.pathname === "/api/portal-access/revoke";
  });
  await page.getByRole("button", { name: "Definitief intrekken" }).click();
  const revokeResponse = await revokeResponsePromise;
  assert.equal(revokeResponse.ok(), true);
  assertResponseShape(await revokeResponse.json(), {
    operation: "revoke",
    selectedCount: 1,
    changedCount: 1,
    unchangedCount: 0,
    groupCount: 1,
    inviteJobCount: 0,
    committed: true,
    reused: false,
  });
  const adaRowLocator = page
    .getByRole("row")
    .filter({ hasText: "Ada Toegang" });
  await adaRowLocator.getByText("Ingetrokken", { exact: true }).waitFor();
  const adaRow = await adaRowLocator.innerText();
  const benRow = await page
    .getByRole("row")
    .filter({ hasText: "Ben Toegang" })
    .innerText();
  assert.match(adaRow, /Ingetrokken/);
  assert.match(benRow, /Actief/);

  await page.setViewportSize({ width: 360, height: 800 });
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.body.clientWidth,
    scrollWidth: document.body.scrollWidth,
  }));
  assert.ok(dimensions.scrollWidth <= dimensions.clientWidth);
  await assertNoAutomatedA11yViolations(page, "parent_access_mobile");

  const databaseState = queryScalar(
    local.DB_URL,
    `
      select
        (select count(*) from private.parent_accounts
          where email_normalized = '${fixtureEmail}')
        || ':' ||
        (select count(*) from private.parent_portal_grants
          where member_season_id in (
            '${memberSeasonIds[0]}'::uuid,
            '${memberSeasonIds[1]}'::uuid
          ) and status = 'active')
        || ':' ||
        (select count(*) from private.parent_portal_grants
          where member_season_id in (
            '${memberSeasonIds[0]}'::uuid,
            '${memberSeasonIds[1]}'::uuid
          ) and status = 'revoked')
        || ':' ||
        (select count(*) from private.email_jobs
          where context_kind = 'portal_access'
            and parent_account_id = (
              select id from private.parent_accounts
              where email_normalized = '${fixtureEmail}'
            ))
        || ':' ||
        coalesce((
          select (payload ? 'children')::text
          from private.email_jobs
          where context_kind = 'portal_access'
            and parent_account_id = (
              select id from private.parent_accounts
              where email_normalized = '${fixtureEmail}'
            )
          limit 1
        ), 'missing')
        || ':' ||
        (select count(*)
          from app.audit_logs audit
          where audit.actor_user_id = '${userId}'::uuid
            and exists (
              select 1
              from jsonb_path_query(
                audit.metadata,
                'strict $.** ? (@.type() == "string")'
              ) leaked(value)
              where (leaked.value #>> '{}')
                  ~ '(^|[^[:alnum:]])(Ada|Ben)([^[:alnum:]]|$)'
                or lower(leaked.value #>> '{}') like any(array[
                  '%2014-01-02%',
                  '%2012-03-04%',
                  '%parent-access-browser@example.invalid%',
                  '%parent-access-browser-staff@example.invalid%',
                  '%parent-access-browser-pepper-2026-with-safe-length%'
                ])
            ));
    `,
  );
  assert.equal(databaseState, "1:1:1:1:false:0");

  process.stdout.write(
    "Portaaltoegang-browsertest geslaagd: echte AAL2-login, gemaskeerde zoekrespons, gedeeld-accountpreflight, mailpreview, activatie, intrekking, mobiele layout en PII-vrije audit bewezen.\n",
  );
} catch (error) {
  process.stderr.write(
    `Portaaltoegang-browsertest mislukt: ${
      error instanceof Error ? error.message : "ONBEKENDE_FOUT"
    }\n`,
  );
  throw error;
} finally {
  await browser?.close();
  await stopApp(appProcess);
  try {
    setActiveSeason(local.DB_URL, previousActiveSeason);
    runSql(local.DB_URL, cleanupSql());
  } catch {
    // Auth-opruiming wordt nog geprobeerd; er worden geen fixturewaarden gelogd.
  }
  if (userId) {
    await admin.auth.admin.deleteUser(userId);
  }
}
