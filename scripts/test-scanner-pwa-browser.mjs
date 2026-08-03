import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import net from "node:net";
import { chromium } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

if (process.env.SCANNER_BROWSER_DISPOSABLE_DB !== "1") {
  throw new Error(
    "De scannerbrowsertest vereist een expliciet wegwerpbare lokale database.",
  );
}

const host = "localhost";
const port = 3120;
const baseUrl = `http://${host}:${port}`;
const qrPepper = process.env.QR_TOKEN_PEPPER;
const qrKeyVersion = Number(process.env.QR_TOKEN_PEPPER_VERSION ?? "1");
if (
  !qrPepper
  || !/^[A-Za-z0-9_-]{43}$/u.test(qrPepper)
  || Buffer.from(qrPepper, "base64url").byteLength !== 32
  || Buffer.from(qrPepper, "base64url").toString("base64url") !== qrPepper
  || !Number.isInteger(qrKeyVersion)
  || qrKeyVersion < 1
  || qrKeyVersion > 9999
) {
  throw new Error("De scannerbrowsertest mist een geldige lokale QR-sleutel.");
}

const ids = {
  staff: crypto.randomUUID(),
  season: crypto.randomUUID(),
  firstArticle: crypto.randomUUID(),
  secondArticle: crypto.randomUUID(),
  firstVariant: crypto.randomUUID(),
  secondVariant: crypto.randomUUID(),
  member: crypto.randomUUID(),
  order: crypto.randomUUID(),
  firstLine: crypto.randomUUID(),
  secondLine: crypto.randomUUID(),
};
const firstArticleName = "Scanner testshirt";
const secondArticleName = "Scanner testbroek";
const hiddenMemberFacts = [
  "Afgeschermdeachternaam",
  "scanner-private@example.invalid",
  "SCANNER-PRIVATE-001",
  "JO15-PRIVE",
  "2012-03-04",
];
const parentPepper = crypto
  .createHash("sha256")
  .update("duindorp-scanner-browser-parent-pepper", "utf8")
  .digest("base64url");

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

function assertLocalDatabase(databaseUrl) {
  const parsed = new URL(databaseUrl);
  if (
    !["127.0.0.1", "localhost"].includes(parsed.hostname)
    || parsed.pathname !== "/postgres"
  ) {
    throw new Error(
      "De scannerbrowsertest mag uitsluitend tegen de lokale Supabase-database draaien.",
    );
  }
}

function sql(databaseUrl, query, capture = false) {
  const result = execFileSync(
    "psql",
    [databaseUrl, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-At", "-c", query],
    {
      encoding: "utf8",
      stdio: capture
        ? ["ignore", "pipe", "ignore"]
        : ["ignore", "ignore", "inherit"],
    },
  );
  return capture ? result.trim() : "";
}

function fixtureSql() {
  return `
    begin;
    insert into app.staff_profiles(auth_user_id, display_name, role)
    values ('${ids.staff}', 'Scanner browseruitgifte', 'uitgifte');

    insert into app.seasons(id, name, default_amount_cents, status)
    values ('${ids.season}', 'Scanner browserseizoen', 13000, 'open');
    update app.app_settings
    set active_season_id = '${ids.season}',
        pickup_location = 'Free-Kick Sport, De Savornin Lohmanplein 45, 2566 AE Den Haag'
    where id = true;

    insert into app.articles(id, name, code, sort_order, active)
    values
      ('${ids.firstArticle}', '${firstArticleName}', 'SCANNER-SHIRT', 991, true),
      ('${ids.secondArticle}', '${secondArticleName}', 'SCANNER-BROEK', 992, true);
    insert into app.article_seasons(article_id, season_id)
    values
      ('${ids.firstArticle}', '${ids.season}'),
      ('${ids.secondArticle}', '${ids.season}');
    insert into app.article_variants(id, article_id, size, sku, active)
    values
      ('${ids.firstVariant}', '${ids.firstArticle}', '152', 'SCANNER-SHIRT-152', true),
      ('${ids.secondVariant}', '${ids.secondArticle}', '152', 'SCANNER-BROEK-152', true);

    insert into app.members(
      id,
      relation_number,
      first_name,
      last_name,
      email,
      team,
      gender
    ) values (
      '${ids.member}',
      'SCANNER-PRIVATE-001',
      'NoaScan',
      'Afgeschermdeachternaam',
      'scanner-private@example.invalid',
      'JO15-PRIVE',
      'female'
    );
    update private.member_sensitive_identity
    set date_of_birth = date '2012-03-04'
    where member_id = '${ids.member}';

    insert into app.member_orders(id, member_id, season_id, amount_due_cents)
    values ('${ids.order}', '${ids.member}', '${ids.season}', 13000);
    insert into app.order_lines(id, order_id, article_variant_id)
    values
      ('${ids.firstLine}', '${ids.order}', '${ids.firstVariant}'),
      ('${ids.secondLine}', '${ids.order}', '${ids.secondVariant}');

    select set_config('app.package_size_internal', 'on', true);
    insert into app.member_article_sizes(
      member_id,
      season_id,
      article_id,
      article_variant_id,
      member_season_id,
      selection_status,
      selection_source,
      confirmed_at
    )
    select
      '${ids.member}',
      '${ids.season}',
      input.article_id,
      input.variant_id,
      member_season.id,
      'confirmed',
      'staff',
      timezone('utc', now()) - interval '1 hour'
    from (
      values
        ('${ids.firstArticle}'::uuid, '${ids.firstVariant}'::uuid),
        ('${ids.secondArticle}'::uuid, '${ids.secondVariant}'::uuid)
    ) input(article_id, variant_id)
    join app.member_seasons member_season
      on member_season.member_id = '${ids.member}'
      and member_season.season_id = '${ids.season}'
    on conflict (member_id, season_id, article_id) do update
    set article_variant_id = excluded.article_variant_id,
        member_season_id = excluded.member_season_id,
        selection_status = excluded.selection_status,
        selection_source = excluded.selection_source,
        raw_value = null,
        member_note = null,
        confirmed_at = excluded.confirmed_at,
        updated_at = timezone('utc', now());
    select set_config('app.package_size_internal', 'off', true);

    insert into app.payments(
      order_id,
      method,
      status,
      amount_cents,
      idempotency_key,
      paid_at
    ) values (
      '${ids.order}',
      'cash',
      'paid',
      13000,
      'scanner-browser-payment-${ids.order}',
      timezone('utc', now()) - interval '30 minutes'
    );

    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      on_hand_delta,
      source_type,
      reason_code,
      idempotency_key
    ) values (
      '${ids.season}',
      '${ids.firstArticle}',
      '${ids.firstVariant}',
      'opening_balance',
      1,
      'scanner_browser',
      'scanner_browser.opening_first',
      encode(
        extensions.digest(
          'scanner-browser-opening-first:${ids.order}',
          'sha256'
        ),
        'hex'
      )
    );

    insert into private.release_cutovers(key)
    values ('allocation_qr_v2')
    on conflict (key) do nothing;
    update app.release_feature_flags
    set enabled = true
    where key in ('allocation_qr_v2', 'scanner_pwa_v2');
    select private.allocate_inventory_fifo_variant(
      '${ids.season}',
      '${ids.firstVariant}',
      'scanner_browser'
    );
    commit;
  `;
}

function secondDeliverySql() {
  return `
    begin;
    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      on_hand_delta,
      source_type,
      reason_code,
      idempotency_key
    ) values (
      '${ids.season}',
      '${ids.secondArticle}',
      '${ids.secondVariant}',
      'opening_balance',
      1,
      'scanner_browser',
      'scanner_browser.opening_second',
      encode(
        extensions.digest(
          'scanner-browser-opening-second:${ids.order}',
          'sha256'
        ),
        'hex'
      )
    );
    select private.allocate_inventory_fifo_variant(
      '${ids.season}',
      '${ids.secondVariant}',
      'scanner_browser'
    );
    commit;
  `;
}

function deriveLocator() {
  const key = Buffer.from(qrPepper, "base64url");
  const generation = 1;
  const nonce = crypto.randomBytes(32).toString("base64url");
  const opaque = crypto
    .createHmac("sha256", key)
    .update(
      [
        "duindorp-qr-locator:v2",
        `k${qrKeyVersion}`,
        ids.order,
        generation,
        nonce,
      ].join(":"),
      "utf8",
    )
    .digest("base64url");
  const locator = `q2.k${qrKeyVersion}.${opaque}`;
  const locatorHash = crypto
    .createHmac("sha256", key)
    .update(`duindorp-qr-lookup:v2:${locator}`, "utf8")
    .digest("hex");
  const pepperFingerprint = crypto
    .createHash("sha256")
    .update("duindorp-qr-pepper:v2:", "utf8")
    .update(key)
    .digest("hex");
  return {
    generation,
    locator,
    locatorHash,
    nonce,
    pepperFingerprint,
  };
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
      throw new Error("De scannertestapp stopte tijdens het opstarten.");
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
  throw new Error("De scannertestapp werd niet tijdig bereikbaar.");
}

async function assertNoBrowserQrStorage(page) {
  const state = await page.evaluate(async () => {
    const indexedDatabases = typeof indexedDB.databases === "function"
      ? await indexedDB.databases()
      : [];
    return {
      cacheKeys: await caches.keys(),
      indexedDatabases: indexedDatabases.map((database) => database.name),
      localStorageValues: Object.values(localStorage),
      sessionStorageValues: Object.values(sessionStorage),
    };
  });
  if (
    state.cacheKeys.length !== 0
    || state.indexedDatabases.length !== 0
    || [...state.localStorageValues, ...state.sessionStorageValues].some(
      (value) => value.includes("q2.") || value.includes("sg2."),
    )
  ) {
    throw new Error("De scanner bewaarde QR- of uitgiftegegevens in browseropslag.");
  }
}

async function exchange(page, locator, expectedReadyArticle) {
  const [response] = await Promise.all([
    page.waitForResponse((candidate) =>
      candidate.url() === `${baseUrl}/api/fulfilment/exchange`
      && candidate.request().method() === "POST"),
    page.getByLabel("QR-code of beveiligde fragmentlink").fill(locator)
      .then(() =>
        page.getByRole("button", { name: "Pakket controleren" }).click()),
  ]);
  if (!response.ok()) {
    throw new Error(
      `De beveiligde QR-exchange gaf onverwacht HTTP ${response.status()}.`,
    );
  }
  await page.getByRole("heading", { name: "NoaScan", exact: true }).waitFor();
  await page.getByText("Meisje/vrouw", { exact: true }).waitFor();
  await page.getByText(expectedReadyArticle, { exact: true }).waitFor();
  const body = await page.locator("body").innerText();
  if (hiddenMemberFacts.some((fact) => body.includes(fact))) {
    throw new Error("De uitgiftescanner toonde afgeschermde lidgegevens.");
  }
}

async function issueLine(page, articleName, expectedOutcome) {
  const articleLabel = page.locator("label").filter({
    has: page.getByText(articleName, { exact: true }),
  });
  await articleLabel.getByRole("checkbox").check();
  const [response] = await Promise.all([
    page.waitForResponse((candidate) =>
      candidate.url() === `${baseUrl}/api/fulfilment/commit`
      && candidate.request().method() === "POST"),
    page
      .getByRole("button", {
        name: "Geselecteerde artikelen uitgeven (1)",
      })
      .click(),
  ]);
  if (response.status() !== 201) {
    throw new Error(
      `De transactionele uitgifte gaf onverwacht HTTP ${response.status()}.`,
    );
  }
  await page
    .getByRole("heading", { name: expectedOutcome, exact: true })
    .waitFor();
}

const local = localSupabaseEnv();
for (const name of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY"]) {
  if (!local[name]) throw new Error(`Lokale Supabase-status mist ${name}.`);
}
assertLocalDatabase(local.DB_URL);
if (!(await portIsAvailable())) {
  throw new Error(`Poort ${port} is bezet; de test wijzigt geen bestaand proces.`);
}

const admin = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
sql(local.DB_URL, fixtureSql());

const staffSession = await admin
  .schema("app")
  .rpc("create_staff_app_session_for_user", {
    p_auth_user_id: ids.staff,
  });
if (
  staffSession.error
  || !staffSession.data
  || typeof staffSession.data !== "object"
  || typeof staffSession.data.sessionToken !== "string"
) {
  throw new Error("De lokale scannersessie kon niet veilig worden gemaakt.");
}

const qr = deriveLocator();
const registered = await admin
  .schema("app")
  .rpc("register_order_qr_locator", {
    p_derivation_nonce: qr.nonce,
    p_generation: qr.generation,
    p_key_version: qrKeyVersion,
    p_locator_hash: qr.locatorHash,
    p_order_id: ids.order,
    p_pepper_fingerprint: qr.pepperFingerprint,
    p_request_id: crypto.randomUUID(),
  });
if (registered.error) {
  throw new Error("De lokale QR-identiteit kon niet veilig worden vastgelegd.");
}

let appProcess;
let browser;
try {
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
        QR_TOKEN_PEPPER: qrPepper,
        QR_TOKEN_PEPPER_VERSION: String(qrKeyVersion),
        DYNAMIC_IMPORT_ENABLED: "false",
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
    viewport: { width: 390, height: 844 },
    serviceWorkers: "allow",
  });
  await context.addCookies([{
    name: "duindorp_staff_session",
    value: staffSession.data.sessionToken,
    url: baseUrl,
    httpOnly: true,
    sameSite: "Lax",
    expires: Math.floor(Date.now() / 1000) + (8 * 60 * 60),
  }]);

  const requestedUrls = [];
  const referrers = [];
  context.on("request", (request) => {
    requestedUrls.push(request.url());
    const referrer = request.headers().referer;
    if (referrer) referrers.push(referrer);
  });

  const page = await context.newPage();
  const scannerResponse = await page.goto(`${baseUrl}/uitgifte`);
  if (!scannerResponse?.ok()) {
    throw new Error("De scannerpagina kon niet met de medewerkerssessie openen.");
  }
  const permissionsPolicy = scannerResponse.headers()["permissions-policy"] ?? "";
  if (
    !permissionsPolicy.includes("camera=(self)")
    || permissionsPolicy.includes("camera=()")
  ) {
    throw new Error("De scannerroute heeft geen exclusief camerabeleid.");
  }
  await page.getByRole("heading", { name: "Uitgifte", exact: true }).waitFor();

  const manifestResponse = await page.request.get(
    `${baseUrl}/uitgifte/manifest.webmanifest`,
  );
  const manifest = await manifestResponse.json();
  if (
    manifestResponse.status() !== 200
    || manifest.id !== "/uitgifte"
    || manifest.scope !== "/uitgifte"
    || manifest.start_url !== "/uitgifte"
    || manifest.display !== "standalone"
  ) {
    throw new Error("Het scanner-PWA-manifest is niet installeerbaar afgebakend.");
  }
  for (const icon of manifest.icons ?? []) {
    const iconResponse = await page.request.get(`${baseUrl}${icon.src}`);
    if (!iconResponse.ok() || iconResponse.headers()["content-type"] !== "image/png") {
      throw new Error("Een scanner-PWA-icoon kon niet veilig worden geladen.");
    }
  }

  await page.evaluate(async () => navigator.serviceWorker.ready);
  await page.reload();
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
  await assertNoBrowserQrStorage(page);

  const reopened = await context.newPage();
  await reopened.goto(`${baseUrl}/uitgifte`);
  await reopened.getByRole("heading", { name: "Uitgifte", exact: true }).waitFor();
  await reopened.close();

  await exchange(page, qr.locator, firstArticleName);
  await issueLine(page, firstArticleName, "Deeluitgifte voltooid");
  sql(local.DB_URL, secondDeliverySql());
  await page.getByRole("button", { name: "Nieuwe scan" }).click();
  await exchange(page, qr.locator, secondArticleName);
  await page.locator("label").filter({
    has: page.getByText(firstArticleName, { exact: true }),
  }).getByText(/Afgehaald/u).waitFor();
  await issueLine(page, secondArticleName, "Pakket volledig uitgegeven");
  await assertNoBrowserQrStorage(page);

  if (
    requestedUrls.some((url) => url.includes(qr.locator))
    || referrers.some((referrer) => referrer.includes(qr.locator))
    || page.url().includes(qr.locator)
  ) {
    throw new Error("De QR-locator lekte naar URL, geschiedenis of referrer.");
  }

  await context.setOffline(true);
  const offlineResponse = await page.goto(
    `${baseUrl}/uitgifte`,
    { waitUntil: "domcontentloaded" },
  );
  if (
    offlineResponse?.status() !== 503
    || !(await page.locator("body").innerText()).includes(
      "Uitgifte werkt uitsluitend online",
    )
  ) {
    throw new Error("De scanner bood offline ten onrechte een uitgifteflow.");
  }
  await context.setOffline(false);

  const evidence = JSON.parse(sql(
    local.DB_URL,
    `
      select jsonb_build_object(
        'pickedUp', (
          select count(*) from app.order_lines
          where order_id = '${ids.order}' and status = 'picked_up'
        ),
        'fulfilments', (
          select count(*) from app.fulfilments
          where order_id = '${ids.order}'
        ),
        'activeLocators', (
          select count(*) from private.qr_order_locators
          where order_id = '${ids.order}' and active
        ),
        'partialEvents', (
          select count(*) from private.fulfilment_notification_events
          where order_id = '${ids.order}' and event_type = 'partial_pickup'
        ),
        'completeEvents', (
          select count(*) from private.fulfilment_notification_events
          where order_id = '${ids.order}' and event_type = 'package_complete'
        )
      )::text
    `,
    true,
  ));
  if (
    evidence.pickedUp !== 2
    || evidence.fulfilments !== 2
    || evidence.activeLocators !== 1
    || evidence.partialEvents !== 1
    || evidence.completeEvents !== 1
  ) {
    throw new Error("Het transactionele scannerbewijs is niet sluitend.");
  }

  process.stdout.write(
    "Scanner-PWA-browsertest geslaagd: sessie, minimale data, netwerk-only, deel- en nalevering met dezelfde QR.\n",
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
}
