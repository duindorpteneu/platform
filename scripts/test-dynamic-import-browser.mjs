import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import net from "node:net";
import { chromium } from "@playwright/test";
import { createBrowserClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import {
  assertKeyboardFocusVisible,
  assertNoAutomatedA11yViolations,
} from "./browser-a11y.mjs";

const host = "localhost";
const port = 3110;
const baseUrl = `http://${host}:${port}`;
const email = "dynamic-import-browser@example.invalid";
const password = "Duindorp-Import-2026!Sterk";
const articleId = "eb100000-0000-4000-8000-000000000001";
const variantId = "eb110000-0000-4000-8000-000000000001";
const articleCode = "BROWSER-IMPORT-SHIRT";
const fileName = "dynamic-browser-import.csv";
const manualRelationNumber = "BROWSER-MANUAL-001";
const cronSecret = "dynamic-import-browser-cron-secret";
const stagingKey = crypto
  .createHash("sha256")
  .update("duindorp-dynamic-import-browser-key")
  .digest("base64url");
const parentPepper = "dynamic-import-browser-parent-pepper-2026";

function localSupabaseEnv() {
  const output = execFileSync(
    "pnpm",
    ["exec", "supabase", "status", "-o", "env"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  );
  return Object.fromEntries(
    output
      .split(/\r?\n/u)
      .filter((line) => line.includes("="))
      .map((line) => {
        const separator = line.indexOf("=");
        return [
          line.slice(0, separator),
          line.slice(separator + 1).replace(/^["']|["']$/gu, ""),
        ];
      }),
  );
}

function sql(databaseUrl, query, capture = false) {
  const result = execFileSync(
    "psql",
    [databaseUrl, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-At", "-c", query],
    {
      encoding: "utf8",
      stdio: capture ? ["ignore", "pipe", "ignore"] : ["ignore", "ignore", "inherit"],
    },
  );
  return capture ? result.trim() : "";
}

function cleanupSql(userId, featureFlag) {
  return `
    begin;
    set local session_replication_role = replica;
    create temporary table browser_batches on commit drop as
      select id from app.import_batches
      where file_name = '${fileName}';
    create temporary table browser_actors on commit drop as
      select actor_user_id id from app.import_batches
      where id in (select id from browser_batches)
      union select '${userId}'::uuid;
    create temporary table browser_runs on commit drop as
      select id from app.dynamic_import_runs
      where batch_id in (select id from browser_batches);
    create temporary table browser_members on commit drop as
      select id from app.members
      where imported_from_batch_id in (select id from browser_batches)
         or relation_number = '${manualRelationNumber}';
    create temporary table browser_member_seasons on commit drop as
      select id from app.member_seasons
      where member_id in (select id from browser_members);

    delete from app.audit_logs
    where actor_user_id in (select id from browser_actors)
      or entity_id in (select id from browser_batches)
      or entity_id in (select id from browser_members)
      or entity_id = '${articleId}';
    delete from app.action_items
    where object_id in (select id from browser_batches)
      or object_id in (select id from browser_member_seasons)
      or source_id in (select id from browser_batches)
      or source_id in (select id from browser_runs);
    delete from private.parent_portal_grants
    where member_season_id in (select id from browser_member_seasons);
    delete from app.member_size_selection_history
    where member_season_id in (select id from browser_member_seasons);
    delete from app.member_article_sizes
    where member_id in (select id from browser_members);
    delete from private.inventory_allocation_queue
    where article_variant_id = '${variantId}';
    delete from private.dynamic_import_run_leases
    where run_id in (select id from browser_runs);
    delete from private.dynamic_import_row_plans
    where run_id in (select id from browser_runs);
    delete from private.dynamic_import_selected_rows
    where run_id in (select id from browser_runs);
    delete from app.dynamic_import_row_results
    where run_id in (select id from browser_runs);
    delete from private.operation_runs operation_run
    where operation_run.operation = 'import_worker'
      and operation_run.started_at >= coalesce(
        (select min(batch.created_at) from app.import_batches batch
          where batch.id in (select id from browser_batches)),
        'infinity'::timestamptz
      );
    delete from app.dynamic_import_runs
    where id in (select id from browser_runs);
    delete from app.member_external_identities
    where member_id in (select id from browser_members);
    delete from private.member_sensitive_identity
    where member_id in (select id from browser_members);
    delete from app.member_seasons
    where id in (select id from browser_member_seasons);
    delete from app.members
    where id in (select id from browser_members);
    update app.import_batches
    set active_mapping_revision_id = null
    where id in (select id from browser_batches);
    delete from app.import_mapping_revisions
    where batch_id in (select id from browser_batches);
    delete from private.import_staging_payloads
    where batch_id in (select id from browser_batches);
    delete from app.import_batches
    where id in (select id from browser_batches);
    delete from app.article_variant_aliases
    where article_variant_id = '${variantId}';
    delete from app.article_seasons where article_id = '${articleId}';
    delete from app.article_variants where article_id = '${articleId}';
    delete from app.articles where id = '${articleId}';
    delete from app.staff_profiles
    where auth_user_id in (select id from browser_actors)
       or display_name = 'Dynamische import browser';
    update app.release_feature_flags
    set enabled = ${featureFlag === "t" ? "true" : "false"}
    where key = 'dynamic_import_v2';
    commit;
  `;
}

function fixtureSql(userId) {
  return `
    begin;
    insert into app.staff_profiles(auth_user_id, display_name, role)
    values('${userId}', 'Dynamische import browser', 'beheerder');
    insert into app.articles(id, name, code, icon_type, active, sort_order)
    values(
      '${articleId}',
      'Import browsertestshirt',
      '${articleCode}',
      'shirt',
      true,
      990
    );
    insert into app.article_variants(
      id, article_id, size, sku, active, sort_order
    )
    values(
      '${variantId}',
      '${articleId}',
      '152',
      'BROWSER-IMPORT-152',
      true,
      1
    );
    insert into app.article_seasons(article_id, season_id)
    select '${articleId}', active_season_id
    from app.app_settings
    where id = true and active_season_id is not null;
    update app.release_feature_flags
    set enabled = true
    where key = 'dynamic_import_v2';
    commit;
  `;
}

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.replace(/=+$/u, "").toUpperCase()) {
    const position = alphabet.indexOf(character);
    if (position < 0) throw new Error("Ongeldig TOTP-secret ontvangen.");
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

function csvBuffer() {
  const rows = [
    [
      "Relatienummer",
      "Voornaam",
      "Achternaam",
      "Team",
      "Geboortedatum",
      "Geslacht",
      "Maat Shirt",
      "Genegeerd",
    ].join(";"),
  ];
  for (let index = 1; index <= 99; index += 1) {
    rows.push([
      `BROWSER-IMPORT-${String(index).padStart(3, "0")}`,
      `Import${index}`,
      "Browser",
      index === 99 ? "" : "JO9-1",
      "2014-01-01",
      index === 99 ? "niet-bestaand" : index % 2 === 0 ? "male" : "female",
      index === 99 ? "XXXL" : "152",
      `NIET-BEWAREN-${index}`,
    ].join(";"));
  }
  for (let index = 0; index < 2; index += 1) {
    rows.push([
      "BROWSER-IMPORT-DUP",
      "Dubbele",
      "Identiteit",
      "JO9-1",
      "2014-02-02",
      "other",
      "152",
      `NIET-BEWAREN-DUP-${index}`,
    ].join(";"));
  }
  return Buffer.from(rows.join("\n"), "utf8");
}

async function portIsAvailable() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => server.close(() => resolve(true)));
    server.listen(port, host);
  });
}

async function waitForApp(process) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (process.exitCode !== null) {
      throw new Error("De importtestapp stopte tijdens het opstarten.");
    }
    try {
      const response = await fetch(`${baseUrl}/staff/login`, {
        redirect: "manual",
      });
      if (response.status === 200) return;
    } catch {
      // De lokale productie-app start nog.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("De importtestapp werd niet tijdig bereikbaar.");
}

async function runWorkerUntil(expectedStatus, maxInvocations = 10) {
  let processed = 0;
  for (let invocation = 1; invocation <= maxInvocations; invocation += 1) {
    const response = await fetch(`${baseUrl}/api/internal/jobs/imports`, {
      method: "POST",
      headers: { authorization: `Bearer ${cronSecret}` },
    });
    const body = await response.json();
    if (!response.ok || !["processing", expectedStatus].includes(body.status)) {
      throw new Error(`Importworker eindigde gecontroleerd met HTTP ${response.status}.`);
    }
    processed += body.processed;
    if (body.status === expectedStatus) return { ...body, processed };
  }
  throw new Error(`Importworker bereikte ${expectedStatus} niet binnen ${maxInvocations} aanroepen.`);
}

const local = localSupabaseEnv();
for (const name of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY"]) {
  if (!local[name]) throw new Error(`Lokale Supabase-status mist ${name}.`);
}
if (!(await portIsAvailable())) {
  throw new Error(`Poort ${port} is bezet; de test wijzigt geen bestaand proces.`);
}
const activeSeason = sql(
  local.DB_URL,
  `select coalesce(active_season_id::text, '') from app.app_settings where id`,
  true,
);
if (!activeSeason) {
  throw new Error("De importbrowsertest vereist een lokaal actief open seizoen.");
}
const featureFlag = sql(
  local.DB_URL,
  `select enabled::text from app.release_feature_flags where key = 'dynamic_import_v2'`,
  true,
);
const admin = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const existing = await admin.auth.admin.listUsers();
const staleUser = existing.data?.users?.find((user) => user.email === email);
if (staleUser) {
  sql(local.DB_URL, cleanupSql(staleUser.id, featureFlag));
  await admin.auth.admin.deleteUser(staleUser.id);
}

let userId;
let appProcess;
let browser;
try {
  const created = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (created.error || !created.data.user) {
    throw created.error ?? new Error("Importtestbeheerder kon niet worden aangemaakt.");
  }
  userId = created.data.user.id;
  sql(local.DB_URL, cleanupSql(userId, featureFlag));
  sql(local.DB_URL, fixtureSql(userId));

  appProcess = spawn(
    "pnpm",
    ["start", "--hostname", host, "--port", String(port)],
    {
      detached: true,
      stdio: process.env.DASHBOARD_APP_LOGS === "1" ? "inherit" : "ignore",
      env: {
        ...process.env,
        APP_BASE_URL: baseUrl,
        NEXT_PUBLIC_SUPABASE_URL: local.API_URL,
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: local.ANON_KEY,
        SUPABASE_SECRET_KEY: local.SERVICE_ROLE_KEY,
        PARENT_TOKEN_PEPPER: parentPepper,
        CRON_SECRET: cronSecret,
        DYNAMIC_IMPORT_ENABLED: "true",
        IMPORT_STAGING_ENCRYPTION_KEY: stagingKey,
        IMPORT_RAW_RETENTION_HOURS: "1",
        MOLLIE_ENABLED: "false",
        MOLLIE_API_KEY: "",
        EMAIL_ENABLED: "false",
        SENDGRID_API_KEY: "",
        SENDGRID_FROM_EMAIL: "",
        SENDGRID_REPLY_TO_EMAIL: "",
        SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "",
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
    email,
    password,
  });
  if (localSignIn.error || !localSignIn.data.session) {
    throw new Error("De importbrowsertest kon niet lokaal inloggen.");
  }
  const localEnrollment = await localMfaClient.auth.mfa.enroll({
    factorType: "totp",
    friendlyName: "Dynamische import browsertest",
    issuer: "Duindorp SV",
  });
  if (localEnrollment.error || !localEnrollment.data) {
    throw new Error("De importbrowsertest kon MFA niet instellen.");
  }
  const localVerification = await localMfaClient.auth.mfa.challengeAndVerify({
    factorId: localEnrollment.data.id,
    code: currentTotp(localEnrollment.data.totp.secret),
  });
  if (localVerification.error) {
    throw new Error("De importbrowsertest kon MFA niet bevestigen.");
  }
  const localSession = await localMfaClient.auth.getSession();
  const localAccessToken = localSession.data.session?.access_token;
  if (localSession.error || !localAccessToken) {
    throw new Error("De importbrowsertest mist een bevestigde AAL2-sessie.");
  }
  const browserAuthCookies = [...localAuthCookies.values()].map((cookie) => ({
    name: cookie.name,
    value: cookie.value,
    url: baseUrl,
    sameSite: "Lax",
  }));
  if (browserAuthCookies.length === 0) {
    throw new Error("De importbrowsertest mist de Supabase-sessiecookie.");
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
    throw new Error("De importbrowsertest kon de appsessie niet starten.");
  }
  await page.goto(`${baseUrl}/backoffice`);
  await page.waitForURL(`${baseUrl}/backoffice`);

  await page.goto(`${baseUrl}/backoffice/leden/importeren`);
  await page
    .getByRole("heading", { name: "Sportlink importeren", exact: true })
    .waitFor();
  await page.locator('input[type="file"]').setInputFiles({
    name: fileName,
    mimeType: "text/csv",
    buffer: csvBuffer(),
  });
  await page.getByRole("button", { name: "Uploaden en controleren" }).click();
  await page.getByText("Versleuteld klaargezet", { exact: true }).waitFor();
  await page.getByText("101", { exact: true }).first().waitFor();

  const sizeColumn = page.locator("article").filter({
    has: page.getByRole("heading", { name: "Maat Shirt", exact: true }),
  });
  await sizeColumn.getByLabel("Importdoel").selectOption({
    label: "Import browsertestshirt",
  });
  const ignoredColumn = page.locator("article").filter({
    has: page.getByRole("heading", { name: "Genegeerd", exact: true }),
  });
  if (await ignoredColumn.getByLabel("Importdoel").inputValue() !== "ignore") {
    throw new Error("Een niet-geselecteerde CSV-kolom werd toch gemapt.");
  }
  await page.getByLabel("Optionele problemen negeren en lid toch importeren").check();
  await page.getByRole("button", { name: "Koppeling valideren" }).click();
  await page.getByText("Koppeling gevalideerd", { exact: true }).waitFor();
  await page.getByText(/100 herkend · 0 leeg · 1 onbekend/u).waitFor();
  await assertNoAutomatedA11yViolations(page, "dynamic_import_mapping");
  await assertKeyboardFocusVisible(page, "dynamic_import_mapping");

  const [dryRunResponse] = await Promise.all([
    page.waitForResponse((response) =>
      response.url().endsWith("/api/imports/dry-runs")
      && response.request().method() === "POST"),
    page.getByRole("button", { name: "Dry-run starten" }).click(),
  ]);
  if (!dryRunResponse.ok()) {
    throw new Error(`Dry-run queueën gaf HTTP ${dryRunResponse.status()}.`);
  }
  const previewWorker = await runWorkerUntil("previewed");
  if (previewWorker.processed !== 202) {
    throw new Error(`De previewworker verwerkte ${previewWorker.processed} stappen.`);
  }
  await page
    .getByRole("button", { name: "Veilige rijen definitief importeren" })
    .waitFor({ timeout: 10_000 });

  await page.reload();
  await page
    .getByRole("link", { name: "Status en resultaat hervatten" })
    .first()
    .click();
  await page
    .getByRole("button", { name: "Veilige rijen definitief importeren" })
    .waitFor({ timeout: 10_000 });
  await page.getByText("1–100 van 101", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Volgende" }).click();
  await page.getByText("101–101 van 101", { exact: true }).waitFor();
  await page.getByLabel("Uitkomst").selectOption("conflict");
  await page.getByText("1–2 van 2", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Tijdelijke details" }).first().click();
  await page.getByRole("heading", { name: /Conflictdetails CSV-rij/u }).waitFor();
  await assertNoAutomatedA11yViolations(page, "dynamic_import_conflict");
  if ((await page.locator("body").innerText()).includes("NIET-BEWAREN")) {
    throw new Error("Een genegeerde CSV-waarde verscheen in conflictdetails.");
  }
  await page.getByRole("button", { name: "Conflictdetails sluiten" }).click();

  await page.getByRole("checkbox").check();
  const [commitResponse] = await Promise.all([
    page.waitForResponse((response) =>
      response.url().endsWith("/api/imports/commits")
      && response.request().method() === "POST"),
    page
      .getByRole("button", { name: "Veilige rijen definitief importeren" })
      .click(),
  ]);
  if (!commitResponse.ok()) {
    throw new Error(`Importcommit queueën gaf HTTP ${commitResponse.status()}.`);
  }
  const commitWorker = await runWorkerUntil("committed");
  if (commitWorker.processed !== 101) {
    throw new Error(`De commitworker verwerkte ${commitWorker.processed} rijen.`);
  }
  await page.getByText("Import voltooid", { exact: true }).waitFor({
    timeout: 10_000,
  });

  await page.goto(`${baseUrl}/backoffice/leden`);
  await page.getByRole("button", { name: "Formulier openen" }).click();
  await page.getByLabel("Voornaam *").fill("Handmatig");
  await page.getByLabel("Achternaam *").fill("Browsertest");
  await page.getByLabel("Sportlink-relatienummer").fill(manualRelationNumber);
  await page.getByLabel("Geboortedatum").fill("2013-03-03");
  await page.getByLabel("Geslacht").selectOption("female");
  await page.getByRole("button", { name: "Toevoegen", exact: true }).click();
  await page.getByText(/Lid toegevoegd aan het actieve seizoen/u).waitFor();
  await assertNoAutomatedA11yViolations(page, "manual_member_create");

  const evidence = sql(
    local.DB_URL,
    `
      with target_batch as (
        select id from app.import_batches
        where actor_user_id = '${userId}' and file_name = '${fileName}'
      ),
      target_run as (
        select id from app.dynamic_import_runs
        where batch_id in (select id from target_batch)
      ),
      target_members as (
        select id from app.members
        where imported_from_batch_id in (select id from target_batch)
      )
      select jsonb_build_object(
        'members', (select count(*) from target_members),
        'dob', (
          select count(*) from private.member_sensitive_identity
          where member_id in (select id from target_members)
            and date_of_birth is not null
        ),
        'grants', (
          select count(*) from private.parent_portal_grants grant_row
          join app.member_seasons member_season
            on member_season.id = grant_row.member_season_id
          where member_season.member_id in (select id from target_members)
        ),
        'mailJobs', (
          select count(*) from private.email_jobs job
          join app.member_orders orders on orders.id = job.order_id
          where orders.member_id in (select id from target_members)
        ),
        'rawPayloads', (
          select count(*) from private.import_staging_payloads
          where batch_id in (select id from target_batch)
        ),
        'rowAudits', (
          select count(*) from app.audit_logs
          where action = 'members.import.row.processed'
            and metadata->>'runId' in (select id::text from target_run)
        ),
        'ignoredLeaks', (
          select count(*) from app.audit_logs
          where metadata::text like '%NIET-BEWAREN%'
             or metadata::text like '%XXXL%'
        ) + (
          select count(*) from private.dynamic_import_selected_rows
          where run_id in (select id from target_run)
            and (selected_values::text like '%NIET-BEWAREN%'
              or selected_values::text like '%XXXL%')
        ),
        'membersWithoutTeam', (
          select count(*) from app.members
          where id in (select id from target_members) and team is null
        ),
        'importedSizes', (
          select count(*) from app.member_article_sizes
          where member_id in (select id from target_members)
        ),
        'manualMembers', (
          select count(*) from app.members
          where relation_number = '${manualRelationNumber}' and team is null
        ),
        'manualDob', (
          select count(*)
          from app.members member
          join private.member_sensitive_identity sensitive on sensitive.member_id = member.id
          where member.relation_number = '${manualRelationNumber}'
            and sensitive.date_of_birth = date '2013-03-03'
        ),
        'manualOrders', (
          select count(*) from app.member_orders orders
          join app.members member on member.id = orders.member_id
          where member.relation_number = '${manualRelationNumber}'
        )
      )::text
    `,
    true,
  );
  const parsedEvidence = JSON.parse(evidence);
  const expectedEvidence = {
    members: 99,
    dob: 99,
    grants: 0,
    mailJobs: 0,
    rawPayloads: 0,
    rowAudits: 101,
    ignoredLeaks: 0,
    membersWithoutTeam: 1,
    importedSizes: 98,
    manualMembers: 1,
    manualDob: 1,
    manualOrders: 0,
  };
  if (Object.entries(expectedEvidence).some(
    ([key, value]) => parsedEvidence[key] !== value,
  )) {
    throw new Error(`Onverwacht PII-/importbewijs: ${evidence}`);
  }

  process.stdout.write(
    "Dynamische import-browsertest geslaagd: flexibele mapping, workerresume, conflict, commit, DOB, suppressie en handmatige invoer.\n",
  );
} finally {
  await browser?.close();
  if (appProcess && appProcess.exitCode === null) {
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
  if (userId) {
    if (process.env.DYNAMIC_IMPORT_DISPOSABLE_DB !== "1") {
      try {
        sql(local.DB_URL, cleanupSql(userId, featureFlag));
      } finally {
        await admin.auth.admin.deleteUser(userId);
      }
    } else {
      await admin.auth.admin.deleteUser(userId);
    }
  }
}
