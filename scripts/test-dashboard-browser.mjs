import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import { mkdir } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { chromium } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

const host = "127.0.0.1";
const port = 3100;
const baseUrl = `http://${host}:${port}`;
const email = "dashboard-browser@example.invalid";
const password = "Duindorp-Test-2026!Sterk";
const reuseApp = process.env.DASHBOARD_REUSE_APP === "1";
const memberIds = Array.from({ length: 5 }, (_, index) => `62000000-0000-4000-8000-00000000000${index + 1}`);
const orderIds = Array.from({ length: 5 }, (_, index) => `63000000-0000-4000-8000-00000000000${index + 1}`);
const lineIds = Array.from({ length: 6 }, (_, index) => `64000000-0000-4000-8000-00000000000${index + 1}`);
const paymentIds = [1, 2, 4, 5].map((index) => `65000000-0000-4000-8000-00000000000${index}`);
const articleId = "61000000-0000-4000-8000-000000000001";

function localSupabaseEnv() {
  const output = execFileSync("pnpm", ["exec", "supabase", "status", "-o", "env"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return Object.fromEntries(output.split(/\r?\n/).filter((line) => line.includes("=")).map((line) => {
    const separator = line.indexOf("=");
    return [line.slice(0, separator), line.slice(separator + 1).replace(/^["']|["']$/g, "")];
  }));
}

function runSql(databaseUrl, query) {
  execFileSync("psql", [databaseUrl, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", query], { stdio: "ignore" });
}

function sqlList(values) {
  return values.map((value) => `'${value}'`).join(", ");
}

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.replace(/=+$/, "").toUpperCase()) {
    const position = alphabet.indexOf(character);
    if (position < 0) throw new Error("Ongeldig TOTP-secret ontvangen.");
    bits += position.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let index = 0; index + 8 <= bits.length; index += 8) bytes.push(Number.parseInt(bits.slice(index, index + 8), 2));
  return Buffer.from(bytes);
}

function currentTotp(secret) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30_000)));
  const digest = crypto.createHmac("sha1", decodeBase32(secret)).update(counter).digest();
  const offset = digest[digest.length - 1] & 15;
  return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000).toString().padStart(6, "0");
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
    if (process?.exitCode !== null && process?.exitCode !== undefined) {
      throw new Error("De productie-app stopte tijdens het opstarten.");
    }
    try {
      const response = await fetch(`${baseUrl}/staff/login`, { redirect: "manual" });
      if (response.status === 200) return;
    } catch {
      // De server start nog op.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("De productie-app werd niet binnen 30 seconden bereikbaar.");
}

function cleanupSql(userId) {
  return `
    delete from app.audit_logs where actor_user_id = '${userId}' or entity_id in (${sqlList([...orderIds, articleId])});
    delete from app.payments where id in (${sqlList(paymentIds)});
    delete from app.order_lines where id in (${sqlList(lineIds)});
    delete from app.member_orders where id in (${sqlList(orderIds)});
    delete from app.members where relation_number = 'DSV-BROWSER-IMPORT';
    delete from app.members where id in (${sqlList(memberIds)});
    delete from app.import_batches where file_name = 'browser-import.csv';
    delete from app.article_variants where id = '${articleId}';
    delete from app.articles where id = '${articleId}';
    delete from app.staff_profiles where auth_user_id = '${userId}';
  `;
}

function fixtureSql(userId) {
  return `
    insert into app.staff_profiles (auth_user_id, display_name, role)
    values ('${userId}', 'Sprint Review', 'beheerder');
    insert into app.articles (id, name, sort_order)
    values ('${articleId}', 'Sprint testartikel', 99);
    insert into app.article_variants (id, article_id, size, sku)
    values ('${articleId}', '${articleId}', 'M', 'SPRINT-M');

    insert into app.members (id, relation_number, first_name, insertion, last_name, email, team) values
      ('${memberIds[0]}', 'DSV-S01', 'Sophie', null, 'de Bruin', 'sophie@example.invalid', 'JO11-1'),
      ('${memberIds[1]}', 'DSV-S02', 'Yassin', null, 'El Amrani', 'yassin@example.invalid', 'JO13-2'),
      ('${memberIds[2]}', 'DSV-S03', 'Lotte', null, 'Jansen', 'lotte@example.invalid', 'MO15-1'),
      ('${memberIds[3]}', 'DSV-S04', 'Milan', null, 'Visser', 'milan@example.invalid', 'JO17-1'),
      ('${memberIds[4]}', 'DSV-S05', 'Noa', null, 'Smit', 'noa@example.invalid', 'MO17-1');

    insert into app.member_orders (id, member_id, season_id, amount_due_cents, order_status, updated_at)
    select rows.order_id, rows.member_id, settings.active_season_id, 12500, rows.order_status, rows.updated_at
    from app.app_settings settings
    cross join (values
      ('${orderIds[0]}'::uuid, '${memberIds[0]}'::uuid, 'Volledig af te halen', timezone('utc', now()) - interval '1 minute'),
      ('${orderIds[1]}'::uuid, '${memberIds[1]}'::uuid, 'Gedeeltelijk af te halen', timezone('utc', now()) - interval '2 minutes'),
      ('${orderIds[2]}'::uuid, '${memberIds[2]}'::uuid, 'Nog niet betaald', timezone('utc', now()) - interval '3 minutes'),
      ('${orderIds[3]}'::uuid, '${memberIds[3]}'::uuid, 'Nalevering', timezone('utc', now()) - interval '4 minutes'),
      ('${orderIds[4]}'::uuid, '${memberIds[4]}'::uuid, 'Afgerond', timezone('utc', now()) - interval '5 minutes')
    ) as rows(order_id, member_id, order_status, updated_at)
    where settings.id = true;

    insert into app.order_lines (id, order_id, article_variant_id, quantity, status) values
      ('${lineIds[0]}', '${orderIds[0]}', '${articleId}', 1, 'ready_for_pickup'),
      ('${lineIds[1]}', '${orderIds[1]}', '${articleId}', 1, 'ready_for_pickup'),
      ('${lineIds[2]}', '${orderIds[1]}', '${articleId}', 1, 'backorder'),
      ('${lineIds[3]}', '${orderIds[2]}', '${articleId}', 1, 'backorder'),
      ('${lineIds[4]}', '${orderIds[3]}', '${articleId}', 1, 'backorder'),
      ('${lineIds[5]}', '${orderIds[4]}', '${articleId}', 1, 'picked_up');

    insert into app.payments (id, order_id, method, status, amount_cents, idempotency_key, paid_at) values
      ('${paymentIds[0]}', '${orderIds[0]}', 'card', 'paid', 12500, 'dashboard-browser-1', timezone('utc', now())),
      ('${paymentIds[1]}', '${orderIds[1]}', 'cash', 'paid', 12500, 'dashboard-browser-2', timezone('utc', now())),
      ('${paymentIds[2]}', '${orderIds[3]}', 'card', 'paid', 12500, 'dashboard-browser-4', timezone('utc', now())),
      ('${paymentIds[3]}', '${orderIds[4]}', 'cash', 'paid', 12500, 'dashboard-browser-5', timezone('utc', now()));

    insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, created_at) values
      ('${userId}', 'fulfilment.completed', 'member_order', '${orderIds[4]}', timezone('utc', now()) - interval '1 minute'),
      ('${userId}', 'stock.lines.reserved', 'member_order', '${orderIds[1]}', timezone('utc', now()) - interval '2 minutes'),
      ('${userId}', 'payment.manual.recorded', 'member_order', '${orderIds[3]}', timezone('utc', now()) - interval '3 minutes'),
      ('${userId}', 'stock.receipt.created', 'article', '${articleId}', timezone('utc', now()) - interval '4 minutes'),
      ('${userId}', 'members.import.commit', 'import_batch', null, timezone('utc', now()) - interval '5 minutes'),
      ('${userId}', 'qr.lookup', 'member_order', '${orderIds[0]}', timezone('utc', now()));
  `;
}

async function verifyDashboard(page, viewport, screenshotPath) {
  await page.setViewportSize(viewport);
  await page.goto(`${baseUrl}/backoffice`);
  if (page.url() !== `${baseUrl}/backoffice`) {
    throw new Error(`Dashboardnavigatie eindigde op ${page.url()}.`);
  }
  try {
    await page.getByRole("heading", { name: "Welkom terug, Sprint" }).waitFor({ timeout: 5_000 });
  } catch {
    const bodySummary = (await page.locator("body").innerText()).replace(/\s+/g, " ").slice(0, 300);
    throw new Error(`De dashboardkop is niet zichtbaar. Pagina: ${bodySummary}`);
  }

  const bodyText = await page.locator("body").innerText();
  const expectedMetrics = [
    ["Actieve leden", "5"],
    ["Betaald", "4"],
    ["Nog niet betaald", "1"],
    ["Gedeeltelijk af te halen", "1"],
    ["Volledig af te halen", "1"],
    ["Naleveringen", "3"],
  ];
  for (const [label, value] of expectedMetrics) {
    const cardText = await page.locator("article").filter({ hasText: label }).first().innerText();
    if (!cardText.split(/\r?\n/).includes(value)) {
      throw new Error(`Dashboard-KPI ${label} heeft niet de verwachte waarde ${value}.`);
    }
  }
  for (const expected of ["2025/26", "Sophie de Bruin", "Uitgifte voltooid"]) {
    if (!bodyText.includes(expected)) throw new Error(`Dashboard mist verwachte tekst: ${expected}`);
  }
  for (const forbidden of ["486", "Danny", "Zaterdag 22 juli", "laatste sync"]) {
    if (bodyText.includes(forbidden)) throw new Error(`Dashboard bevat verouderde fixturetekst: ${forbidden}`);
  }

  const dimensions = await page.evaluate(() => ({
    clientWidth: document.body.clientWidth,
    scrollWidth: document.body.scrollWidth,
  }));
  if (dimensions.scrollWidth > dimensions.clientWidth) {
    throw new Error(`Horizontale body-overflow: ${dimensions.scrollWidth}/${dimensions.clientWidth}`);
  }
  if (screenshotPath) await page.screenshot({ path: screenshotPath, fullPage: true });
}

async function verifyMemberOverview(page, screenshotDir) {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(`${baseUrl}/backoffice/leden`);
  await page.getByRole("heading", { name: "Leden", exact: true }).waitFor({ timeout: 5_000 });
  let bodyText = await page.locator("body").innerText();
  for (const expected of ["5 actief", "5 totaal", "Sophie de Bruin", "Sportlink importeren"]) {
    if (!bodyText.includes(expected)) throw new Error(`Ledenoverzicht mist verwachte tekst: ${expected}`);
  }
  for (const forbidden of ["486 leden", "Liam van der Meer", "sophie@example.invalid"]) {
    if (bodyText.includes(forbidden)) throw new Error(`Ledenlijst bevat preview- of detaildata: ${forbidden}`);
  }

  await page.locator('select[name="team"]').selectOption("JO13-2");
  await page.getByRole("button", { name: "Filters toepassen" }).click();
  await page.waitForURL(/team=JO13-2/);
  await page.getByRole("heading", { name: "Leden", exact: true }).waitFor({ timeout: 5_000 });
  bodyText = await page.locator("body").innerText();
  if (!bodyText.includes("1 resultaten") || !bodyText.includes("Yassin El Amrani") || bodyText.includes("Sophie de Bruin")) {
    throw new Error(`Het server-side teamfilter gaf niet exact het verwachte lid terug: ${bodyText.replace(/\s+/g, " ").slice(-500)}`);
  }

  const detailUrl = `${baseUrl}/backoffice/leden?member=${memberIds[0]}`;
  await page.goto(detailUrl);
  await page.getByRole("heading", { name: "Sophie de Bruin" }).waitFor({ timeout: 5_000 });
  bodyText = await page.locator("body").innerText();
  bodyText = bodyText.replace(/\u00a0/g, " ");
  for (const expected of ["sophie@example.invalid", "€ 125,00", "Volledig af te halen", "Niet aangemaakt", "Sprint testartikel · M"]) {
    if (!bodyText.includes(expected)) throw new Error(`Liddetail mist verwachte tekst: ${expected}`);
  }
  if (bodyText.includes("token_hash") || bodyText.includes("qrToken")) throw new Error("Liddetail toont QR-geheim materiaal.");
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-members-desktop.png"), fullPage: true });

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(detailUrl);
  await page.getByRole("heading", { name: "Sophie de Bruin" }).waitFor({ timeout: 5_000 });
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.body.clientWidth,
    scrollWidth: document.body.scrollWidth,
  }));
  if (dimensions.scrollWidth > dimensions.clientWidth) {
    throw new Error(`Mobiel ledenoverzicht heeft body-overflow: ${dimensions.scrollWidth}/${dimensions.clientWidth}`);
  }
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-member-detail-mobile.png"), fullPage: true });

  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(`${baseUrl}/backoffice/leden`);
  await page.getByRole("heading", { name: "Leden", exact: true }).waitFor({ timeout: 5_000 });
  process.stdout.write("Backoffice-browsertest: Sportlink-preview controleren…\n");
  await page.locator('input[type="file"]').setInputFiles({
    name: "browser-import.csv",
    mimeType: "text/csv",
    buffer: Buffer.from([
      "Relatienummer;Voornaam;Achternaam;E-mailadres;Team;Actief voor seizoen",
      "DSV-BROWSER-IMPORT;Browser;Importlid;browser-import@example.invalid;JO19-1;Ja",
    ].join("\n")),
  });
  await page.getByRole("button", { name: "Kolommen en preview controleren", exact: true }).click();
  await page.getByText("Kolommen gekoppeld en preview gereed").waitFor({ timeout: 5_000 });
  const previewText = await page.locator("section").filter({ hasText: "Sportlink importeren" }).innerText();
  if (!previewText.includes("Nieuw") || !previewText.match(/Nieuw\s+1|1\s+Nieuw/)) {
    throw new Error("Sportlink-preview toont het nieuwe lid niet.");
  }
  process.stdout.write("Backoffice-browsertest: Sportlink-commit controleren…\n");
  const [commitResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/imports/commit") && response.request().method() === "POST"),
    page.getByRole("button", { name: "Import definitief verwerken" }).click(),
  ]);
  if (!commitResponse.ok()) {
    throw new Error(`Sportlink-commit gaf HTTP ${commitResponse.status()}: ${await commitResponse.text()}`);
  }
  await page.getByText("1 leden zijn transactioneel verwerkt.").waitFor({ timeout: 5_000 });
  await page.goto(`${baseUrl}/backoffice/leden?search=DSV-BROWSER-IMPORT`);
  await page.getByRole("heading", { name: "Leden", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByText("Browser Importlid", { exact: true }).waitFor({ timeout: 5_000 });
}

const local = localSupabaseEnv();
for (const name of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY"]) {
  if (!local[name]) throw new Error(`Lokale Supabase-status mist ${name}.`);
}
if (!reuseApp && !(await portIsAvailable())) {
  throw new Error(`Poort ${port} is bezet; de test stopt zonder een bestaand proces te wijzigen.`);
}

const admin = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const existing = await admin.auth.admin.listUsers();
const staleUser = existing.data?.users?.find((user) => user.email === email);
if (staleUser) {
  runSql(local.DB_URL, cleanupSql(staleUser.id));
  await admin.auth.admin.deleteUser(staleUser.id);
}

let userId;
let appProcess;
let browser;
try {
  process.stdout.write("Dashboard-browsertest: tijdelijke fixture aanmaken…\n");
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (created.error || !created.data.user) {
    throw created.error ?? new Error("Testgebruiker kon niet worden aangemaakt.");
  }
  userId = created.data.user.id;
  if (!/^[0-9a-f-]{36}$/.test(userId)) throw new Error("Ongeldig test-user-id ontvangen.");
  runSql(local.DB_URL, fixtureSql(userId));

  if (!reuseApp) {
    process.stdout.write("Dashboard-browsertest: productie-app starten…\n");
    appProcess = spawn("pnpm", ["start", "--hostname", host, "--port", String(port)], {
      detached: true,
      stdio: "ignore",
    });
  }
  await waitForApp(appProcess);
  process.stdout.write("Dashboard-browsertest: browser en AAL2-login controleren…\n");
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  await page.goto(`${baseUrl}/backoffice`);
  await page.waitForURL(`${baseUrl}/staff/login`);
  await page.getByLabel("E-mailadres").fill(email);
  await page.getByLabel("Wachtwoord").fill(password);
  await page.getByRole("button", { name: "Inloggen" }).click();
  await page.waitForURL(`${baseUrl}/staff/mfa`);
  const secret = (await page.locator("p.font-mono").textContent())?.trim();
  if (!secret) throw new Error("De MFA-handmatige sleutel is niet zichtbaar.");
  await page.getByLabel("Zescijferige verificatiecode").fill(currentTotp(secret));
  await page.getByRole("button", { name: "Beveiligde sessie starten" }).click();
  await page.waitForURL(`${baseUrl}/backoffice`);

  process.stdout.write("Dashboard-browsertest: desktop en mobiel controleren…\n");
  const screenshotDir = process.env.DASHBOARD_SCREENSHOT_DIR
    ? path.resolve(process.env.DASHBOARD_SCREENSHOT_DIR)
    : null;
  if (screenshotDir) await mkdir(screenshotDir, { recursive: true });
  await verifyDashboard(
    page,
    { width: 1440, height: 1000 },
    screenshotDir ? path.join(screenshotDir, "after-dashboard-desktop.png") : null,
  );
  await verifyDashboard(
    page,
    { width: 390, height: 844 },
    screenshotDir ? path.join(screenshotDir, "after-dashboard-mobile.png") : null,
  );
  process.stdout.write("Backoffice-browsertest: ledenlijst, detail, filters en import controleren…\n");
  await verifyMemberOverview(page, screenshotDir);

  const unauthenticatedPage = await browser.newPage();
  process.stdout.write("Dashboard-browsertest: anonieme routebeveiliging controleren…\n");
  const response = await unauthenticatedPage.goto(`${baseUrl}/backoffice`, { waitUntil: "domcontentloaded" });
  if (response?.url() !== `${baseUrl}/staff/login`) {
    throw new Error("Een niet-ingelogde browser werd niet naar de medewerkerslogin gestuurd.");
  }

  process.stdout.write(
    "Backoffice-browsertest geslaagd: AAL2, dashboard, ledenlijst, detail, filters, import, responsive layout en routebeveiliging gecontroleerd.\n",
  );
} catch (error) {
  process.stderr.write(`Dashboard-browsertest mislukt: ${error instanceof Error ? error.message : String(error)}\n`);
  throw error;
} finally {
  await browser?.close();
  if (appProcess && appProcess.exitCode === null) {
    const exited = new Promise((resolve) => appProcess.once("exit", resolve));
    try {
      process.kill(-appProcess.pid, "SIGTERM");
    } catch {
      appProcess.kill("SIGTERM");
    }
    await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5_000))]);
  }
  if (userId) {
    try {
      runSql(local.DB_URL, cleanupSql(userId));
    } catch {
      // Auth-cleanup gaat door.
    }
    await admin.auth.admin.deleteUser(userId);
  }
}
