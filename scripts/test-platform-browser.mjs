import { spawnSync } from "node:child_process";
import { mkdir, readFile, writeFile, rm } from "node:fs/promises";
import path from "node:path";

const sourcePath = path.resolve("scripts/test-dashboard-browser.mjs");
const generatedPath = path.resolve(".next/test-dashboard-browser-core.mjs");
const importStart = '  process.stdout.write("Backoffice-browsertest: Sportlink-preview controleren…\\n");';
const importEnd = '  if (await page.getByLabel("Maat Sprint testartikel").inputValue() !== articleIds[0]) throw new Error("Opgeslagen individuele maat bleef na herladen niet geselecteerd.");';

const source = await readFile(sourcePath, "utf8");
const startIndex = source.indexOf(importStart);
const endMarkerIndex = source.indexOf(importEnd, startIndex);
const endIndex = endMarkerIndex < 0 ? -1 : endMarkerIndex + importEnd.length;
if (startIndex < 0 || endIndex < 0) {
  throw new Error("De legacy browserharness kon niet veilig worden geïsoleerd.");
}

await mkdir(path.dirname(generatedPath), { recursive: true });
const parentCleanupBefore =
  "    delete from private.parent_accounts where email_normalized = 'sophie@example.invalid';";
const parentCleanupAfter = [
  "    delete from private.parent_sessions where parent_account_id in (",
  "      select id from private.parent_accounts where email_normalized = 'sophie@example.invalid'",
  "    );",
  "    delete from private.parent_member_links where parent_account_id in (",
  "      select id from private.parent_accounts where email_normalized = 'sophie@example.invalid'",
  "    );",
  "    delete from private.parent_portal_grants where parent_account_id in (",
  "      select id from private.parent_accounts where email_normalized = 'sophie@example.invalid'",
  "    );",
  parentCleanupBefore,
].join("\n");
let generatedSource = `${source.slice(0, startIndex)}${source.slice(endIndex)}`
  .replace(parentCleanupBefore, parentCleanupAfter)
  .replace(
    'variantForm.getByLabel("Maat").fill("164")',
    'variantForm.getByLabel("Maatlabel", { exact: true }).fill("164")',
  )
  .replace(
    'variantForm.getByLabel("Leverancierscode").fill("BROWSER-164")',
    'variantForm.getByLabel("Maatcode / leverancierscode", { exact: true }).fill("BROWSER-164")',
  )
  .replace(
    'page.getByRole("heading", { name: "Voorraad per variant" })',
    'page.getByRole("heading", { name: "Voorraad en vraag per maat" })',
  )
  .replace(
    'await page.getByText("Bevestig kas: € 130,00", { exact: true }).waitFor({ timeout: 5_000 });',
    [
      'await page.getByText("Bevestig kas: € 130,00", { exact: true }).waitFor({ timeout: 5_000 });',
      '  await page.locator("#payment-reason").fill("Contant ontvangen tijdens browseracceptatie");',
    ].join("\n"),
  );

generatedSource = generatedSource.replace(
  [
    "    insert into private.qr_tokens (order_id, token_hash, version, active, created_by)",
    "    values ('${orderIds[0]}', '${qrTokenHash}', 1, true, '${userId}');",
  ].join("\n"),
  "",
);
generatedSource = generatedSource.replace(
  "  runSql(local.DB_URL, fixtureSql(userId));",
  `  runSql(local.DB_URL, fixtureSql(userId));
  const browserQrKeyVersion = Number(process.env.QR_TOKEN_PEPPER_VERSION);
  const browserQrKey = Buffer.from(process.env.QR_TOKEN_PEPPER ?? "", "base64url");
  if (!Number.isInteger(browserQrKeyVersion) || browserQrKey.length !== 32) {
    throw new Error("De browseracceptatie mist een geldige afgeschermde QR-testsleutel.");
  }
  const browserQrNonce = crypto.randomBytes(32).toString("base64url");
  const browserQrOpaque = crypto
    .createHmac("sha256", browserQrKey)
    .update([
      "duindorp-qr-locator:v2",
      \`k\${browserQrKeyVersion}\`,
      orderIds[0],
      1,
      browserQrNonce,
    ].join(":"), "utf8")
    .digest("base64url");
  const browserQrLocator = \`q2.k\${browserQrKeyVersion}.\${browserQrOpaque}\`;
  const browserQrRegistration = await admin.schema("app").rpc(
    "register_order_qr_locator",
    {
      p_derivation_nonce: browserQrNonce,
      p_generation: 1,
      p_key_version: browserQrKeyVersion,
      p_locator_hash: crypto
        .createHmac("sha256", browserQrKey)
        .update(\`duindorp-qr-lookup:v2:\${browserQrLocator}\`, "utf8")
        .digest("hex"),
      p_order_id: orderIds[0],
      p_pepper_fingerprint: crypto
        .createHash("sha256")
        .update("duindorp-qr-pepper:v2:", "utf8")
        .update(browserQrKey)
        .digest("hex"),
      p_request_id: crypto.randomUUID(),
    },
  );
  if (browserQrRegistration.error) {
    throw new Error("De browseracceptatie kon de veilige QR-fixture niet registreren.");
  }
  runSql(local.DB_URL, \`
    insert into app.inventory_allocations(
      id,
      season_id,
      member_id,
      member_season_id,
      order_id,
      order_line_id,
      article_id,
      article_variant_id,
      quantity,
      status,
      reconciliation_status,
      allocation_mode,
      paid_at,
      size_valid_at,
      priority_at,
      product_name_snapshot,
      size_snapshot,
      legacy_reservation_id,
      allocated_at,
      fulfilled_at,
      allocated_by,
      fulfilled_by
    )
    select
      '6b000000-0000-4000-8000-000000000001',
      orders.season_id,
      orders.member_id,
      orders.member_season_id,
      orders.id,
      line.id,
      line.article_id,
      line.article_variant_id,
      line.quantity,
      'fulfilled',
      'resolved',
      'legacy_preserved',
      payment.paid_at,
      payment.paid_at,
      payment.paid_at,
      line.product_name_snapshot,
      line.size_snapshot,
      reservation.id,
      reservation.created_at,
      fulfilment_line.created_at,
      reservation.actor_user_id,
      fulfilment.actor_user_id
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    join app.inventory_reservations reservation
      on reservation.order_line_id = line.id
      and reservation.status = 'fulfilled'
    join app.fulfilment_lines fulfilment_line
      on fulfilment_line.reservation_id = reservation.id
      and fulfilment_line.reversed_at is null
    join app.fulfilments fulfilment on fulfilment.id = fulfilment_line.fulfilment_id
    join lateral (
      select paid.paid_at
      from app.payments paid
      where paid.order_id = orders.id and paid.status = 'paid'
      order by paid.paid_at, paid.id
      limit 1
    ) payment on true
    where line.id = '64000000-0000-4000-8000-000000000006';

    insert into app.inventory_allocation_events(
      allocation_id,
      event_type,
      previous_status,
      next_status,
      reason_code,
      source_type,
      source_id,
      idempotency_key,
      safe_context,
      created_at
    ) values (
      '6b000000-0000-4000-8000-000000000001',
      'legacy_preserved',
      null,
      'fulfilled',
      'legacy.browser_fixture',
      'inventory_reservation',
      '68000000-0000-4000-8000-000000000001',
      repeat('e', 64),
      '{}'::jsonb,
      timezone('utc', now()) - interval '30 seconds'
    );

    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      on_hand_delta,
      reserved_delta,
      issued_delta,
      allocation_id,
      source_type,
      source_id,
      reason_code,
      idempotency_key,
      safe_context,
      occurred_at
    )
    select
      allocation.season_id,
      allocation.article_id,
      allocation.article_variant_id,
      'opening_balance',
      0,
      0,
      allocation.quantity,
      allocation.id,
      'inventory_reservation',
      allocation.legacy_reservation_id,
      'legacy.browser_fixture',
      repeat('f', 64),
      '{}'::jsonb,
      allocation.allocated_at
    from app.inventory_allocations allocation
    where allocation.id = '6b000000-0000-4000-8000-000000000001';

    update app.fulfilment_lines
    set inventory_allocation_id = '6b000000-0000-4000-8000-000000000001'
    where id = '6a000000-0000-4000-8000-000000000001';
  \`);`,
);
const issuanceStart = generatedSource.indexOf(
  "async function verifyStockAndIssuanceSurfaces",
);
const issuanceEnd = generatedSource.indexOf(
  "async function verifyOperationsSprint",
  issuanceStart,
);
if (issuanceStart < 0 || issuanceEnd < 0) {
  throw new Error("De legacy uitgiftebrowserflow kon niet veilig worden vervangen.");
}
const scannerPwaReview = `async function verifyStockAndIssuanceSurfaces(page, screenshotDir) {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(\`\${baseUrl}/backoffice/leveringen\`);
  await page.getByRole("heading", { name: "Leveringen", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByRole("heading", { name: "Voorraad en vraag per maat" }).waitFor({ timeout: 5_000 });
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "after-deliveries-desktop.png"), fullPage: true });

  await page.setViewportSize({ width: 390, height: 844 });
  const scannerResponse = await page.goto(\`\${baseUrl}/uitgifte\`);
  if (!scannerResponse?.ok()) throw new Error("Scannerpagina kon niet online worden geopend.");
  await page.getByRole("heading", { name: "Uitgifte", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByLabel("QR-code of beveiligde fragmentlink").waitFor();
  if (screenshotDir) await page.screenshot({ path: path.join(screenshotDir, "issuance-empty-mobile.png"), fullPage: true });

  const manifestResponse = await page.request.get(\`\${baseUrl}/uitgifte/manifest.webmanifest\`);
  const manifest = await manifestResponse.json();
  if (
    manifestResponse.status() !== 200
    || manifest.id !== "/uitgifte"
    || manifest.scope !== "/uitgifte"
    || manifest.start_url !== "/uitgifte"
  ) throw new Error("Scannermanifest heeft niet de canonieke installatiescope.");
  const workerResponse = await page.request.get(\`\${baseUrl}/uitgifte/scanner-sw.js\`);
  if (
    workerResponse.status() !== 200
    || workerResponse.headers()["service-worker-allowed"] !== "/uitgifte"
    || !workerResponse.headers()["cache-control"]?.includes("no-store")
  ) throw new Error("Scanner-serviceworker mist zijn smalle no-store contract.");

  await page.evaluate(async () => navigator.serviceWorker.ready);
  await page.reload();
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
  const pwaState = await page.evaluate(async () => ({
    cacheKeys: await caches.keys(),
    controlled: Boolean(navigator.serviceWorker.controller),
    scope: (await navigator.serviceWorker.ready).scope,
  }));
  if (!pwaState.controlled || !pwaState.scope.endsWith("/uitgifte") || pwaState.cacheKeys.length !== 0) {
    throw new Error("Scanner-PWA is niet gecontroleerd netwerk-only geïnstalleerd.");
  }

  await page.getByRole("button", { name: "Scan QR-code" }).click();
  await page.getByRole("alert").filter({ hasText: "Cameratoegang is niet beschikbaar" }).waitFor({ timeout: 10_000 });

  await page.context().setOffline(true);
  const offlineResponse = await page.goto(\`\${baseUrl}/uitgifte\`, { waitUntil: "domcontentloaded" });
  if (offlineResponse?.status() !== 503 || !(await page.textContent("body"))?.includes("Uitgifte werkt uitsluitend online")) {
    throw new Error("Scanner bood offline ten onrechte een uitgifteflow.");
  }
  await page.context().setOffline(false);
}`;
generatedSource = `${generatedSource.slice(0, issuanceStart)}${scannerPwaReview}\n\n${generatedSource.slice(issuanceEnd)}`;

await writeFile(
  generatedPath,
  generatedSource,
  { encoding: "utf8", mode: 0o600 },
);

function run(script, extraEnv = {}) {
  const result = spawnSync(process.execPath, [script], {
    cwd: process.cwd(),
    env: { ...process.env, ...extraEnv },
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${path.basename(script)} mislukte met status ${result.status}.`);
  }
}

function resetLocalDatabase() {
  const result = spawnSync("pnpm", ["db:reset"], {
    cwd: process.cwd(),
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`Lokale testdatabase resetten mislukte met status ${result.status}.`);
  }
}

resetLocalDatabase();
try {
  const qrPepper = Buffer.alloc(32, 11).toString("base64url");
  run(generatedPath, {
    QR_TOKEN_PEPPER: qrPepper,
    QR_TOKEN_PEPPER_VERSION: "1",
  });
  run(path.resolve("scripts/test-dynamic-import-browser.mjs"), {
    DYNAMIC_IMPORT_DISPOSABLE_DB: "1",
  });
  run(path.resolve("scripts/test-scanner-pwa-browser.mjs"), {
    QR_TOKEN_PEPPER: qrPepper,
    QR_TOKEN_PEPPER_VERSION: "1",
    SCANNER_BROWSER_DISPOSABLE_DB: "1",
  });
} finally {
  await rm(generatedPath, { force: true });
  resetLocalDatabase();
}
