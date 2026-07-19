import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import { mkdir, readFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { chromium } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

const host = "localhost";
const port = 3100;
const baseUrl = `http://${host}:${port}`;
const email = "dashboard-browser@example.invalid";
const password = "Duindorp-Test-2026!Sterk";
const reuseApp = process.env.DASHBOARD_REUSE_APP === "1";
const memberIds = Array.from({ length: 5 }, (_, index) => `62000000-0000-4000-8000-00000000000${index + 1}`);
const orderIds = Array.from({ length: 5 }, (_, index) => `63000000-0000-4000-8000-00000000000${index + 1}`);
const lineIds = Array.from({ length: 6 }, (_, index) => `64000000-0000-4000-8000-00000000000${index + 1}`);
const paymentIds = [1, 2, 4, 5].map((index) => `65000000-0000-4000-8000-00000000000${index}`);
const articleIds = [
  "61000000-0000-4000-8000-000000000001",
  "61000000-0000-4000-8000-000000000002",
];
const receiptId = "66000000-0000-4000-8000-000000000001";
const receiptLineId = "67000000-0000-4000-8000-000000000001";
const reservationId = "68000000-0000-4000-8000-000000000001";
const fulfilmentId = "69000000-0000-4000-8000-000000000001";
const fulfilmentLineId = "6a000000-0000-4000-8000-000000000001";
const formulaMemberId = "62000000-0000-4000-8000-000000000006";

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
    delete from app.audit_logs where actor_user_id = '${userId}' or entity_id in (${sqlList([...orderIds, ...articleIds])});
    delete from app.email_events where email_job_id in (
      select id from private.email_jobs
      where order_id in (${sqlList(orderIds)})
        or batch_id in (select id from app.email_batches where actor_user_id = '${userId}')
    );
    delete from private.email_jobs
    where order_id in (${sqlList(orderIds)})
      or batch_id in (select id from app.email_batches where actor_user_id = '${userId}');
    delete from app.email_batches where actor_user_id = '${userId}';
    delete from app.fulfilment_lines where fulfilment_id in (select id from app.fulfilments where order_id in (${sqlList(orderIds)}));
    delete from app.fulfilments where order_id in (${sqlList(orderIds)});
    delete from app.inventory_reservations where order_line_id in (select id from app.order_lines where order_id in (${sqlList(orderIds)}));
    delete from private.qr_tokens where order_id in (${sqlList(orderIds)});
    delete from app.payments where order_id in (${sqlList(orderIds)});
    delete from app.order_lines where order_id in (${sqlList(orderIds)});
    delete from app.member_orders where id in (${sqlList(orderIds)});
    delete from app.members where relation_number = 'DSV-BROWSER-IMPORT';
    delete from app.members where id = '${formulaMemberId}';
    delete from app.members where id in (${sqlList(memberIds)});
    delete from app.import_batches where file_name = 'browser-import.csv';
    delete from app.delivery_receipt_lines where receipt_id = '${receiptId}';
    delete from app.delivery_receipts where id = '${receiptId}';
    delete from app.article_seasons where article_id in (select id from app.articles where code in ('SPRINT-TEST', 'SPRINT-BROEK', 'BROWSER-JACK'));
    delete from app.article_variants where article_id in (select id from app.articles where code in ('SPRINT-TEST', 'SPRINT-BROEK', 'BROWSER-JACK'));
    delete from app.articles where code in ('SPRINT-TEST', 'SPRINT-BROEK', 'BROWSER-JACK');
    delete from app.staff_profiles where auth_user_id = '${userId}';
  `;
}

function fixtureSql(userId) {
  return `
    insert into app.staff_profiles (auth_user_id, display_name, role)
    values ('${userId}', 'Sprint Review', 'beheerder');
    insert into app.articles (id, name, code, icon_type, sort_order) values
      ('${articleIds[0]}', 'Sprint testartikel', 'SPRINT-TEST', 'shirt', 99),
      ('${articleIds[1]}', 'Sprint testbroek', 'SPRINT-BROEK', 'circle-dot', 100);
    insert into app.article_variants (id, article_id, size, sku) values
      ('${articleIds[0]}', '${articleIds[0]}', 'M', 'SPRINT-M'),
      ('${articleIds[1]}', '${articleIds[1]}', '152', 'SPRINT-152');
    insert into app.article_seasons (article_id, season_id)
    select article_id, settings.active_season_id
    from app.app_settings settings
    cross join (values ('${articleIds[0]}'::uuid), ('${articleIds[1]}'::uuid)) articles(article_id)
    where settings.id = true;

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
      ('${lineIds[0]}', '${orderIds[0]}', '${articleIds[0]}', 1, 'ready_for_pickup'),
      ('${lineIds[1]}', '${orderIds[1]}', '${articleIds[0]}', 1, 'ready_for_pickup'),
      ('${lineIds[2]}', '${orderIds[1]}', '${articleIds[1]}', 1, 'backorder'),
      ('${lineIds[3]}', '${orderIds[2]}', '${articleIds[0]}', 1, 'backorder'),
      ('${lineIds[4]}', '${orderIds[3]}', '${articleIds[0]}', 1, 'backorder'),
      ('${lineIds[5]}', '${orderIds[4]}', '${articleIds[0]}', 1, 'picked_up');

    insert into app.payments (id, order_id, method, status, amount_cents, idempotency_key, paid_at) values
      ('${paymentIds[0]}', '${orderIds[0]}', 'card', 'paid', 12500, 'dashboard-browser-1', timezone('utc', now())),
      ('${paymentIds[1]}', '${orderIds[1]}', 'cash', 'paid', 12500, 'dashboard-browser-2', timezone('utc', now())),
      ('${paymentIds[2]}', '${orderIds[3]}', 'card', 'paid', 12500, 'dashboard-browser-4', timezone('utc', now())),
      ('${paymentIds[3]}', '${orderIds[4]}', 'cash', 'paid', 12500, 'dashboard-browser-5', timezone('utc', now()));

    insert into private.qr_tokens (order_id, token_hash, version, active, created_by)
    values ('${orderIds[0]}', repeat('1', 64), 1, true, '${userId}');

    insert into app.delivery_receipts (id, received_on, supplier, packing_slip_reference, actor_user_id)
    values ('${receiptId}', current_date, 'Sprint browserleverancier', 'BROWSER-PAK', '${userId}');
    insert into app.delivery_receipt_lines (id, receipt_id, article_variant_id, received_quantity)
    values ('${receiptLineId}', '${receiptId}', '${articleIds[0]}', 1);
    insert into app.inventory_reservations (id, receipt_line_id, order_line_id, quantity, status, actor_user_id)
    values ('${reservationId}', '${receiptLineId}', '${lineIds[5]}', 1, 'fulfilled', '${userId}');
    insert into app.fulfilments (id, order_id, actor_user_id, location, created_at)
    values ('${fulfilmentId}', '${orderIds[4]}', '${userId}', 'Browserbalie', timezone('utc', now()) - interval '30 seconds');
    insert into app.fulfilment_lines (id, fulfilment_id, order_line_id, reservation_id, quantity)
    values ('${fulfilmentLineId}', '${fulfilmentId}', '${lineIds[5]}', '${reservationId}', 1);

    insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, created_at) values
      ('${userId}', 'fulfilment.completed', 'member_order', '${orderIds[4]}', timezone('utc', now()) - interval '1 minute'),
      ('${userId}', 'stock.lines.reserved', 'member_order', '${orderIds[1]}', timezone('utc', now()) - interval '2 minutes'),
      ('${userId}', 'payment.manual.recorded', 'member_order', '${orderIds[3]}', timezone('utc', now()) - interval '3 minutes'),
      ('${userId}', 'stock.receipt.created', 'article', '${articleIds[0]}', timezone('utc', now()) - interval '4 minutes'),
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
    const bodySummary = (await page.locator("body").innerText()).replace(/\s+/g, " ").slice(0, 1500);
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
  for (const expected of ["sophie@example.invalid", "€ 125,00", "Volledig af te halen", "Actief", "Sprint testartikel · M"]) {
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

async function verifyOperationsSprint(page, screenshotDir) {
  await page.setViewportSize({ width: 1440, height: 1000 });
  process.stdout.write("Operations-browsertest: catalogusartikel en variant aanmaken…\n");
  await page.goto(`${baseUrl}/backoffice/artikelen`);
  await page.getByRole("heading", { name: "Artikelen en maten" }).waitFor({ timeout: 5_000 });
  await page.getByRole("button", { name: "Artikel toevoegen" }).first().click();
  const articleForm = page.locator("form").filter({ hasText: "Tenueonderdeel toevoegen" });
  await articleForm.getByLabel("Naam").fill("Browser trainingsjack");
  await articleForm.getByLabel("Korte code").fill("BROWSER-JACK");
  await articleForm.getByLabel("Icoon").selectOption("package");
  await articleForm.getByLabel("Sorteervolgorde").fill("110");
  await articleForm.getByRole("button", { name: "Artikel toevoegen" }).click();
  await page.getByText("Artikel toegevoegd.", { exact: true }).waitFor({ timeout: 5_000 });
  await page.reload();
  await page.getByRole("heading", { name: "Artikelen en maten" }).waitFor({ timeout: 5_000 });
  await page.getByRole("button", { name: /Browser trainingsjack/ }).click();

  const variantForm = page.locator("form").filter({ hasText: "Variant toevoegen" });
  await variantForm.getByLabel("Maat").fill("164");
  await variantForm.getByLabel("Leverancierscode").fill("BROWSER-164");
  await variantForm.getByLabel("Volgorde").fill("10");
  await variantForm.getByRole("button", { name: "Variant toevoegen" }).click();
  await page.getByText("Variant toegevoegd.", { exact: true }).waitFor({ timeout: 5_000 });
  await page.getByText("BROWSER-164", { exact: true }).waitFor({ timeout: 5_000 });
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-catalog-desktop.png"), fullPage: true });

  process.stdout.write("Operations-browsertest: open bestelling wijzigen en betaalde bestelling vergrendelen…\n");
  await page.goto(`${baseUrl}/backoffice/bestellingen`);
  await page.getByRole("heading", { name: "Bestellingen" }).waitFor({ timeout: 5_000 });
  await page.getByPlaceholder("Naam, team of relatienummer").fill("Lotte");
  await page.getByRole("button", { name: /Lotte Jansen/ }).click();
  const orderForm = page.locator("form").filter({ hasText: "Lotte Jansen" });
  await orderForm.getByLabel(/Exact verschuldigd bedrag/).fill("130,00");
  const jacketRow = orderForm.locator("div.rounded-xl").filter({ hasText: "Browser trainingsjack" });
  await jacketRow.getByRole("combobox").selectOption({ label: "164 · BROWSER-164" });
  const [saveResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/orders/save") && response.request().method() === "POST"),
    orderForm.getByRole("button", { name: "Bestelling opslaan" }).click(),
  ]);
  if (!saveResponse.ok()) {
    throw new Error(`Bestelling opslaan gaf HTTP ${saveResponse.status()}: ${await saveResponse.text()}`);
  }
  await page.getByText("Bestelling bijgewerkt en geaudit.", { exact: true }).waitFor({ timeout: 10_000 });
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-orders-desktop.png"), fullPage: true });

  await page.getByPlaceholder("Naam, team of relatienummer").fill("Sophie");
  await page.getByRole("button", { name: /Sophie de Bruin/ }).click();
  await page.getByText("Betaald · alleen-lezen", { exact: true }).waitFor({ timeout: 5_000 });
  if (await page.getByRole("button", { name: "Bestelling opslaan" }).isEnabled()) {
    throw new Error("Een betaalde bestelling is in de browser niet alleen-lezen.");
  }

  process.stdout.write("Operations-browsertest: QR roteren, intrekken en opnieuw activeren…\n");
  const detailUrl = `${baseUrl}/backoffice/leden?member=${memberIds[0]}`;
  await page.goto(detailUrl);
  await page.getByRole("heading", { name: "Sophie de Bruin" }).waitFor({ timeout: 5_000 });
  await page.getByLabel("Verplichte reden").first().fill("Ouder meldde verlies");
  const [rotateResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/qr/rotate") && response.request().method() === "POST"),
    page.getByRole("button", { name: "QR roteren" }).click(),
  ]);
  if (!rotateResponse.ok()) {
    throw new Error(`QR-rotatie gaf HTTP ${rotateResponse.status()}: ${await rotateResponse.text()}`);
  }
  await page.getByText("Nieuwe QR-versie is actief; de oude code is direct ongeldig.", { exact: true }).waitFor({ timeout: 5_000 });
  await page.getByLabel("Verplichte reden").first().fill("Tijdelijk veiligheidsincident");
  await page.getByRole("button", { name: "QR intrekken" }).click();
  await page.getByText("De QR-code is direct ingetrokken.", { exact: true }).waitFor({ timeout: 5_000 });
  await page.reload();
  await page.getByRole("heading", { name: "Sophie de Bruin" }).waitFor({ timeout: 5_000 });
  await page.getByText("Ingetrokken", { exact: true }).waitFor({ timeout: 5_000 });
  await page.getByLabel("Verplichte reden").first().fill("Nieuwe code na intrekking");
  await page.getByRole("button", { name: "Nieuwe QR activeren" }).click();
  await page.getByText("Nieuwe QR-versie is actief; de oude code is direct ongeldig.", { exact: true }).waitFor({ timeout: 5_000 });
  await page.reload();
  await page.getByRole("heading", { name: "Sophie de Bruin" }).waitFor({ timeout: 5_000 });
  await page.getByText("Actief", { exact: true }).last().waitFor({ timeout: 5_000 });
  await page.setViewportSize({ width: 390, height: 844 });
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-member-security-mobile.png"), fullPage: true });

  process.stdout.write("Operations-browsertest: foutieve uitgifte transactioneel corrigeren…\n");
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(`${baseUrl}/backoffice/uitgifte`);
  await page.getByRole("heading", { name: "Uitgiftes en correcties" }).waitFor({ timeout: 5_000 });
  await page.getByText("Noa Smit", { exact: true }).waitFor({ timeout: 5_000 });
  await page.getByRole("checkbox").check();
  await page.getByLabel("Doelstatus").selectOption("backorder");
  await page.getByLabel("Verplichte reden").fill("Artikel bleek niet meegegeven");
  const [correctionResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/fulfilment/reverse") && response.request().method() === "POST"),
    page.getByRole("button", { name: "Correctie bevestigen" }).click(),
  ]);
  if (!correctionResponse.ok()) {
    throw new Error(`Uitgiftecorrectie gaf HTTP ${correctionResponse.status()}: ${await correctionResponse.text()}`);
  }
  await page.getByText("1 regel(s) transactioneel gecorrigeerd.", { exact: true }).waitFor({ timeout: 10_000 });
  await page.reload();
  await page.getByRole("heading", { name: "Uitgiftes en correcties" }).waitFor({ timeout: 10_000 });
  await page.getByText(/Gecorrigeerd/).waitFor({ timeout: 10_000 });
  const historyText = await page.locator("body").innerText();
  if (!historyText.includes("Reden: Artikel bleek niet meegegeven") || !historyText.includes("Nalevering")) {
    throw new Error("Uitgiftecorrectie is niet volledig zichtbaar in de operationele historie.");
  }
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-corrections-desktop.png"), fullPage: true });
}

async function verifyProviderSprint(page, screenshotDir) {
  process.stdout.write("Provider-browsertest: e-mailcentrum en bulkcontrole controleren…\n");
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(`${baseUrl}/backoffice/emails`);
  await page.getByRole("heading", { name: "E-mailcentrum" }).waitFor({ timeout: 5_000 });
  for (const expected of ["Verzending gepauzeerd", "6", "Verificatiecode", "Betalingsherinnering"]) {
    if (!(await page.locator("body").innerText()).includes(expected)) throw new Error(`E-mailcentrum mist verwachte tekst: ${expected}`);
  }
  await page.getByRole("button", { name: /Verificatiecode/ }).click();
  await page.getByLabel("Onderwerp").waitFor({ state: "visible" });
  if (await page.getByLabel("Onderwerp").isDisabled() || await page.getByLabel("Berichttekst").isDisabled()) {
    throw new Error("De ouder-OTP-template is niet bewerkbaar in het e-mailcentrum.");
  }
  await page.getByLabel("Berichttekst").fill("Uw tijdelijke voorbeeldcode is {{verificatiecode}}. Vragen? {{contact_email}}");
  await page.getByRole("button", { name: "Fictief voorbeeld" }).click();
  await page.getByText(/Uw tijdelijke voorbeeldcode is 123456/).waitFor({ timeout: 5_000 });
  await page.getByRole("button", { name: "Template opslaan" }).waitFor({ state: "visible" });
  await page.getByRole("button", { name: "Bulkmail" }).click();
  await page.getByRole("heading", { name: "Bestellingen selecteren" }).waitFor({ timeout: 5_000 });
  await page.getByText("Elk geselecteerd lid krijgt één afzonderlijk bericht.").waitFor({ timeout: 5_000 });
  const emailDimensions = await page.evaluate(() => ({ clientWidth: document.body.clientWidth, scrollWidth: document.body.scrollWidth }));
  if (emailDimensions.scrollWidth > emailDimensions.clientWidth) throw new Error("E-mailcentrum heeft horizontale body-overflow.");
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-email-center-desktop.png"), fullPage: true });

  process.stdout.write("Provider-browsertest: operationeel betaalregister controleren…\n");
  await page.goto(`${baseUrl}/backoffice/betalingen`);
  await page.getByRole("heading", { name: "Betalingen", exact: true }).waitFor({ timeout: 5_000 });
  const paymentBody = await page.locator("body").innerText();
  for (const expected of ["open of onderweg", "betaald", "recente betaalpogingen", "kas"]) {
    if (!paymentBody.toLowerCase().includes(expected)) throw new Error(`Betaalregister mist verwachte tekst: ${expected}. Pagina: ${paymentBody.replace(/\s+/g, " ").slice(0, 500)}`);
  }
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-payments-desktop.png"), fullPage: true });

  process.stdout.write("Provider-browsertest: neutrale Mollie-retourpagina mobiel controleren…\n");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`${baseUrl}/betaling/terug`);
  await page.getByRole("heading", { name: "Betaling wordt gecontroleerd" }).waitFor({ timeout: 5_000 });
  const returnText = await page.locator("body").innerText();
  if (!returnText.includes("Deze pagina markeert een bestelling nooit zelf als betaald.")) {
    throw new Error("De Mollie-retourpagina mist de webhook-first veiligheidsmelding.");
  }
  const returnDimensions = await page.evaluate(() => ({ clientWidth: document.body.clientWidth, scrollWidth: document.body.scrollWidth }));
  if (returnDimensions.scrollWidth > returnDimensions.clientWidth) throw new Error("Mollie-retourpagina heeft horizontale body-overflow.");
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-payment-return-mobile.png"), fullPage: true });
}

async function verifyReleaseHardening(page, databaseUrl, screenshotDir) {
  process.stdout.write("Release-browsertest: exacte kasbetaling controleren…\n");
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(`${baseUrl}/backoffice/leden?member=${memberIds[2]}`);
  await page.getByRole("heading", { name: "Lotte Jansen" }).waitFor({ timeout: 5_000 });
  await page.getByRole("button", { name: "Kas", exact: true }).click();
  await page.getByText("Bevestig kas: € 130,00", { exact: true }).waitFor({ timeout: 5_000 });
  const [paymentResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/payments/manual") && response.request().method() === "POST"),
    page.getByRole("button", { name: "Exact registreren" }).click(),
  ]);
  if (!paymentResponse.ok()) throw new Error(`Handmatige betaling gaf HTTP ${paymentResponse.status()}: ${await paymentResponse.text()}`);
  await page.getByText("De exacte kasbetaling van € 130,00 is geregistreerd.", { exact: true }).waitFor({ timeout: 5_000 });

  process.stdout.write("Release-browsertest: settings en audit controleren…\n");
  const settingsResponse = await page.goto(`${baseUrl}/backoffice/instellingen`);
  await page.getByRole("heading", { name: "Instellingen", exact: true }).waitFor({ timeout: 5_000 });
  for (const expected of ["Duindorp SV", "SAFETY SWITCHES", "Medewerkers", "Beheerder · AAL2"]) {
    if (!(await page.locator("body").innerText()).includes(expected)) throw new Error(`Instellingen mist verwachte tekst: ${expected}`);
  }
  const securityHeaders = settingsResponse?.headers() ?? {};
  for (const name of ["content-security-policy", "x-content-type-options", "x-frame-options", "referrer-policy", "permissions-policy", "x-correlation-id"]) {
    if (!securityHeaders[name]) throw new Error(`Productieresponse mist securityheader ${name}.`);
  }
  if (!securityHeaders["content-security-policy"].includes("frame-ancestors 'none'")) throw new Error("CSP mist frame-ancestors none.");
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-settings-desktop.png"), fullPage: true });

  await page.goto(`${baseUrl}/backoffice/audit`);
  await page.getByRole("heading", { name: "Auditlog", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByText("payment.manual.recorded", { exact: true }).first().waitFor({ timeout: 5_000 });
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-audit-desktop.png"), fullPage: true });

  process.stdout.write("Release-browsertest: formuleveilige CSV/XLSX-export controleren…\n");
  runSql(databaseUrl, `insert into app.members (id, relation_number, first_name, last_name, email, team) values ('${formulaMemberId}', 'DSV-FORMULA', '=CMD', 'Test', 'formula@example.invalid', 'TEST-1');`);
  await page.goto(`${baseUrl}/backoffice/export`);
  await page.getByRole("heading", { name: "Exports", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByLabel("Seizoen").selectOption("");
  const csvEvent = page.waitForEvent("download");
  await page.getByRole("link", { name: "CSV" }).click();
  const csvDownload = await csvEvent;
  const csvPath = await csvDownload.path();
  if (!csvPath) throw new Error("CSV-download heeft geen lokaal testpad.");
  const csv = await readFile(csvPath, "utf8");
  if (!csv.startsWith("\uFEFF")) throw new Error("CSV-export mist UTF-8 BOM.");
  if (!csv.includes("'=CMD Test") || csv.includes('"=CMD Test"')) throw new Error("CSV-export neutraliseert formulegevoelige tekst niet.");
  if (!/^duindorp-sv-leden-alle-seizoenen-\d{4}-\d{2}-\d{2}\.csv$/.test(csvDownload.suggestedFilename())) throw new Error(`Onveilige exportbestandsnaam: ${csvDownload.suggestedFilename()}`);
  const xlsxEvent = page.waitForEvent("download");
  await page.getByRole("link", { name: "Excel" }).click();
  const xlsxDownload = await xlsxEvent;
  const xlsxPath = await xlsxDownload.path();
  if (!xlsxPath || (await readFile(xlsxPath)).subarray(0, 2).toString() !== "PK") throw new Error("XLSX-export is geen geldig OOXML-archief.");
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-exports-desktop.png"), fullPage: true });

  process.stdout.write("Release-browsertest: mutatie zonder CSRF-proof weigeren…\n");
  const csrfStatus = await page.evaluate(async () => (await fetch("/api/orders/save", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  })).status);
  if (csrfStatus !== 403) throw new Error(`Mutatie zonder CSRF-proof gaf ${csrfStatus} in plaats van 403.`);
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
      stdio: process.env.DASHBOARD_APP_LOGS === "1" ? "inherit" : "ignore",
      env: {
        ...process.env,
        APP_BASE_URL: baseUrl,
        NEXT_PUBLIC_SUPABASE_URL: local.API_URL,
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: local.ANON_KEY,
        SUPABASE_SECRET_KEY: local.SERVICE_ROLE_KEY,
        PARENT_TOKEN_PEPPER: process.env.PARENT_TOKEN_PEPPER ?? "dashboard-browser-test-pepper-with-32-characters",
        MOLLIE_ENABLED: "false",
        MOLLIE_API_KEY: "",
        EMAIL_ENABLED: "false",
        SENDGRID_API_KEY: "",
        SENDGRID_FROM_EMAIL: "",
        SENDGRID_REPLY_TO_EMAIL: "",
        SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "",
      },
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
  await verifyOperationsSprint(page, screenshotDir);
  await verifyProviderSprint(page, screenshotDir);
  await verifyReleaseHardening(page, local.DB_URL, screenshotDir);

  const unauthenticatedPage = await browser.newPage();
  process.stdout.write("Dashboard-browsertest: anonieme routebeveiliging controleren…\n");
  const response = await unauthenticatedPage.goto(`${baseUrl}/backoffice`, { waitUntil: "domcontentloaded" });
  if (response?.url() !== `${baseUrl}/staff/login`) {
    throw new Error("Een niet-ingelogde browser werd niet naar de medewerkerslogin gestuurd.");
  }

  process.stdout.write(
    "Backoffice-browsertest geslaagd: AAL2, dashboard, leden, import, catalogus, bestellingen, exacte kasbetaling, QR-beheer, uitgiftecorrecties, e-mailcentrum, betaalregister, Mollie-retour, exports, settings, audit, securityheaders, CSRF, responsive layout en routebeveiliging gecontroleerd.\n",
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
