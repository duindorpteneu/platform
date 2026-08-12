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
let generatedSource = `${
  'import { assertKeyboardFocusVisible, assertNoAutomatedA11yViolations, assertReducedMotionHonored } '
  + 'from "../scripts/browser-a11y.mjs";\n'
}${source.slice(0, startIndex)}${source.slice(endIndex)}`
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
    "  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });",
    [
      "  const staffContext = await browser.newContext({",
      "    viewport: { width: 1440, height: 1000 },",
      "  });",
      "  const page = await staffContext.newPage();",
    ].join("\n"),
  )
  .replace(
    'await page.getByText("Bevestig kas: € 130,00", { exact: true }).waitFor({ timeout: 5_000 });',
    [
      'await page.getByText("Bevestig kas: € 130,00", { exact: true }).waitFor({ timeout: 5_000 });',
      '  await page.locator("#payment-reason").fill("Contant ontvangen tijdens browseracceptatie");',
    ].join("\n"),
  );

const legacyEmailEditorCheck = `  for (const expected of ["Verzending gepauzeerd", "6", "Verificatiecode", "Betalingsherinnering"]) {
    if (!(await page.locator("body").innerText()).includes(expected)) throw new Error(\`E-mailcentrum mist verwachte tekst: \${expected}\`);
  }
  await page.getByRole("button", { name: /Verificatiecode/ }).click();
  await page.getByLabel("Onderwerp").waitFor({ state: "visible" });
  if (await page.getByLabel("Onderwerp").isDisabled() || await page.getByLabel("Berichttekst").isDisabled()) {
    throw new Error("De ouder-OTP-template is niet bewerkbaar in het e-mailcentrum.");
  }
  await page.getByLabel("Berichttekst").fill("Uw tijdelijke voorbeeldcode is {{verificatiecode}}. Vragen? {{contact_email}}");
  await page.getByRole("button", { name: "Fictief voorbeeld" }).click();
  await page.getByText(/Uw tijdelijke voorbeeldcode is 123456/).waitFor({ timeout: 5_000 });
  await page.getByRole("button", { name: "Template opslaan" }).waitFor({ state: "visible" });`;
const mailV2EditorCheck = `  for (const expected of ["Verzending gepauzeerd", "19", "Inlogcode", "Betalingsherinnering"]) {
    if (!(await page.locator("body").innerText()).includes(expected)) throw new Error(\`E-mailcentrum mist verwachte tekst: \${expected}\`);
  }
  await page.getByRole("button", { name: /Inlogcode/ }).click();
  await page.waitForFunction(() => {
    const labels = [...document.querySelectorAll("label")];
    const label = labels.find((candidate) => candidate.textContent?.includes("Interne naam"));
    return label?.querySelector("input")?.value === "Inlogcode";
  }, undefined, { timeout: 5_000 });
  await page.getByLabel("Onderwerp").waitFor({ state: "visible" });
  for (const label of ["Interne naam", "Onderwerp", "Preheader"]) {
    if (await page.getByLabel(label, { exact: true }).isDisabled()) {
      throw new Error(\`Mail-v2-veld is ten onrechte vergrendeld: \${label}\`);
    }
  }
  const [mailPreviewResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/email/v2/templates/preview") && response.request().method() === "POST"),
    page.getByRole("button", { name: "Preview", exact: true }).click(),
  ]);
  if (!mailPreviewResponse.ok()) {
    const previewFailure = await mailPreviewResponse.json().catch(() => ({}));
    const previewRequest = mailPreviewResponse.request().postDataJSON();
    const bodyDocument = previewRequest && typeof previewRequest === "object"
      ? previewRequest.bodyTipTap
      : null;
    const previewRequestShape = {
      bodyContentCount: bodyDocument
        && typeof bodyDocument === "object"
        && Array.isArray(bodyDocument.content)
        ? bodyDocument.content.length
        : -1,
      bodyType: bodyDocument && typeof bodyDocument === "object"
        ? String(bodyDocument.type ?? "")
        : typeof bodyDocument,
      internalNameLength: typeof previewRequest?.internalName === "string"
        ? previewRequest.internalName.length
        : -1,
      keys: previewRequest && typeof previewRequest === "object"
        ? Object.keys(previewRequest).sort().join(",")
        : "geen",
      preheaderLength: typeof previewRequest?.preheaderSource === "string"
        ? previewRequest.preheaderSource.length
        : -1,
      subjectLength: typeof previewRequest?.subjectSource === "string"
        ? previewRequest.subjectSource.length
        : -1,
      templateKey: typeof previewRequest?.templateKey === "string"
        ? previewRequest.templateKey
        : "geen",
    };
    const previewFailureCode = typeof previewFailure?.error === "string"
      ? previewFailure.error.replace(/[^A-Za-z0-9À-ž ._-]/gu, "").slice(0, 160)
      : "onbekende fout";
    throw new Error(\`Mail-v2-preview gaf HTTP \${mailPreviewResponse.status()}: \${previewFailureCode}; vorm \${JSON.stringify(previewRequestShape)}\`);
  }
  const mailPreviewFinished = await mailPreviewResponse.finished();
  if (mailPreviewFinished) {
    throw new Error("Mail-v2-previewresponse werd niet volledig ontvangen.");
  }
  const mailPreviewPayload = await mailPreviewResponse.json();
  for (const key of ["subject", "preheader", "html", "text"]) {
    if (typeof mailPreviewPayload?.[key] !== "string") {
      throw new Error(\`Mail-v2-preview mist veilig veld \${key}.\`);
    }
  }
  const mailPreviewSection = page.locator("section").filter({
    hasText: "Fictieve preview",
  }).last();
  await mailPreviewSection.getByText("Fictieve preview", { exact: true }).waitFor({
    state: "visible",
    timeout: 30_000,
  });
  const desktopPreviewMode = mailPreviewSection.locator(
    '[role="group"][aria-label="Previewmodus"] button[aria-label="Desktop"]',
  );
  await desktopPreviewMode.waitFor({ state: "visible", timeout: 10_000 });
  await desktopPreviewMode.click();
  if (await desktopPreviewMode.getAttribute("aria-pressed") !== "true") {
    throw new Error("Mail-v2-preview kon niet aantoonbaar naar desktopmodus schakelen.");
  }
  const mailPreviewFrame = mailPreviewSection.locator("iframe");
  await mailPreviewFrame.waitFor({
    state: "attached",
    timeout: 10_000,
  });
  if (await mailPreviewFrame.getAttribute("title") !== "Preview Inlogcode") {
    throw new Error("Mail-v2-preview heeft niet de verwachte veilige frametitel.");
  }
  if (await mailPreviewFrame.getAttribute("srcdoc") !== mailPreviewPayload.html) {
    throw new Error("Mail-v2-preview rendert niet exact de gevalideerde server-HTML.");
  }
  await mailPreviewFrame.waitFor({
    state: "visible",
    timeout: 10_000,
  });
  await page.getByRole("button", { name: "Branding", exact: true }).click();
  await page.getByRole("heading", { name: "Afzender, contact en afhalen" }).waitFor({
    state: "visible",
    timeout: 10_000,
  });
  const canonicalBrandingFields = [
    ["Afzendernaam", "Kledingcommissie Duindorp SV"],
    ["From-adres", "kleding@duindorpsv.nl"],
    ["Reply-to", "kleding@duindorpsv.nl"],
    ["Contactadres", "kleding@duindorpsv.nl"],
    ["Verenigingsadres", "Houtrustlaan 1"],
    ["Afhaalnaam", "Free-Kick Sport"],
    ["Afhaaladres", "De Savornin Lohmanplein 45"],
    ["Privacyroute", "https://duindorpsv.nl/privacy"],
  ];
  for (const [label, expected] of canonicalBrandingFields) {
    const actual = await page.getByLabel(label, { exact: true }).inputValue();
    if (actual !== expected) {
      throw new Error(\`Brandingveld \${label} bevat niet de canonieke waarde.\`);
    }
  }`;
if (!generatedSource.includes(legacyEmailEditorCheck)) {
  throw new Error("De legacy e-mailbrowsercontrole kon niet veilig worden vervangen.");
}
generatedSource = generatedSource.replace(legacyEmailEditorCheck, mailV2EditorCheck);
const authReadinessNeedle = "const existing = await admin.auth.admin.listUsers();";
if (!generatedSource.includes(authReadinessNeedle)) {
  throw new Error("De Auth-readinessinjectie kon niet veilig worden geplaatst.");
}
generatedSource = generatedSource.replace(
  authReadinessNeedle,
  `let existing;
  let authFailureCategory = "transport-of-provider";
  const authReadyDeadline = Date.now() + 120_000;
  while (Date.now() < authReadyDeadline) {
    const probe = await admin.auth.admin.listUsers({ page: 1, perPage: 1 });
    if (!probe.error) {
      existing = probe;
      break;
    }
    authFailureCategory = Number.isInteger(probe.error.status)
      ? \`http-\${probe.error.status}\`
      : "transport-of-provider";
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  if (!existing) {
    throw new Error(\`Lokale Supabase Auth werd niet tijdig gezond na de schone reset (\${authFailureCategory}).\`);
  }`,
);
const legacySettingsMutation = `  await page.getByLabel("Contactmail").fill("kleding@duindorpsv.nl");
  await page.getByLabel("Verenigingsadres", { exact: true }).fill("Duinlaan 1");
  await page.getByLabel("Postcode").first().fill("2584 AB");
  await page.getByLabel("Plaats").first().fill("Den Haag");
  await page.getByLabel("Afhaaladres wijkt af van het verenigingsadres").check();
  await page.getByLabel("Naam afhaallocatie").fill("Tenuepunt");
  await page.getByLabel("Adres", { exact: true }).fill("Markt 2");
  await page.getByLabel("Postcode").last().fill("2511 AA");
  await page.getByLabel("Plaats").last().fill("Den Haag");
  if (!(await page.getByRole("button", { name: "Instellingen opslaan" }).isEnabled())) throw new Error("Instellingen opslaan is ten onrechte inactief.");
  const [settingsSaveResponse] = await Promise.all([
    page.waitForResponse((response) => response.url().endsWith("/api/settings") && response.request().method() === "POST"),
    page.getByRole("button", { name: "Instellingen opslaan" }).click(),
  ]);
  if (!settingsSaveResponse.ok()) throw new Error(\`Instellingen opslaan gaf HTTP \${settingsSaveResponse.status()}: \${await settingsSaveResponse.text()}\`);
  await page.getByText("De clubinstellingen zijn server-side gevalideerd, opgeslagen en geaudit.", { exact: true }).waitFor({ timeout: 5_000 });`;
const canonicalSettingsCheck = `  const canonicalSettingsText = await page.locator("body").innerText();
  for (const expected of [
    "Houtrustlaan 1",
    "2566 ZW Den Haag",
    "kleding@duindorpsv.nl",
    "Free-Kick Sport",
    "De Savornin Lohmanplein 45",
    "2566 AE Den Haag",
  ]) {
    if (!canonicalSettingsText.includes(expected)) {
      throw new Error(\`Instellingen mist canonieke brandingwaarde: \${expected}\`);
    }
  }`;
if (!generatedSource.includes(legacySettingsMutation)) {
  throw new Error("De legacy instellingenbrowsercontrole kon niet veilig worden vervangen.");
}
generatedSource = generatedSource.replace(
  legacySettingsMutation,
  canonicalSettingsCheck,
);
const legacySeasonAmountCheck = `  await seasonPanel.getByLabel("Standaardbedrag").fill("99,00");`;
const packageAwareSeasonAmountCheck = `  await seasonPanel.getByLabel("Legacybedrag losse order").fill("0,00");`;
if (!generatedSource.includes(legacySeasonAmountCheck)) {
  throw new Error("De legacy seizoensbedragcontrole kon niet veilig worden vervangen.");
}
generatedSource = generatedSource
  .replace(legacySeasonAmountCheck, packageAwareSeasonAmountCheck)
  .replace(
    '  await page.getByLabel("Standaardbedrag Browser 2039/2040").waitFor({ timeout: 5_000 });',
    '  await page.getByLabel("Legacybedrag losse bestelling Browser 2039/2040").waitFor({ timeout: 5_000 });',
  );
const legacyFormulaExportFixture = `  runSql(databaseUrl, \`insert into app.members (id, relation_number, first_name, last_name, email, team) values ('\${formulaMemberId}', 'DSV-FORMULA', '=CMD', 'Test', 'formula@example.invalid', 'TEST-1');\`);
  await page.goto(\`\${baseUrl}/backoffice/export\`);
  await page.getByRole("heading", { name: "Exports", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByLabel("Seizoen").selectOption("");`;
const seasonBoundFormulaExportFixture = `  runSql(databaseUrl, \`
    insert into app.members (
      id, relation_number, first_name, last_name, email, team
    ) values (
      '\${formulaMemberId}', 'DSV-FORMULA', '=CMD', 'Test',
      'formula@example.invalid', 'TEST-1'
    );
    insert into app.member_orders (
      member_id, season_id, amount_due_cents, order_status
    )
    select
      '\${formulaMemberId}', season.id, 0, 'Nog niet betaald'
    from app.seasons season
    where season.name = 'Browser 2039/2040';
  \`);
  await page.goto(\`\${baseUrl}/backoffice/export\`);
  await page.getByRole("heading", { name: "Exports", exact: true }).waitFor({ timeout: 5_000 });
  await page.getByLabel("Seizoen").selectOption({ label: "Browser 2039/2040" });`;
if (!generatedSource.includes(legacyFormulaExportFixture)) {
  throw new Error("De legacy exportseizoencontrole kon niet veilig worden vervangen.");
}
generatedSource = generatedSource
  .replace(legacyFormulaExportFixture, seasonBoundFormulaExportFixture)
  .replace(
    '/^duindorp-sv-leden-alle-seizoenen-\\d{4}-\\d{2}-\\d{2}\\.csv$/',
    '/^duindorp-sv-leden-browser-2039-2040-\\d{4}-\\d{2}-\\d{2}\\.csv$/',
  );

for (const legacyQrFixture of [
  [
    "    insert into private.qr_tokens (order_id, token_hash, version, active, created_by)",
    "    values ('${orderIds[0]}', '${qrTokenHash}', 1, true, '${userId}');",
  ].join("\n"),
  [
    "    insert into private.qr_tokens (order_id, token_hash, version, active, created_by)",
    "    values ('${orderIds[0]}', repeat('1', 64), 1, true, '${userId}');",
  ].join("\n"),
]) {
  generatedSource = generatedSource.replace(legacyQrFixture, "");
}
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
      allocated_at
    )
    select
      '6b000000-0000-4000-8000-000000000002',
      orders.season_id,
      orders.member_id,
      orders.member_season_id,
      orders.id,
      line.id,
      line.article_id,
      line.article_variant_id,
      line.quantity,
      'reserved',
      'resolved',
      'fifo',
      payment.paid_at,
      payment.paid_at,
      payment.paid_at,
      line.product_name_snapshot,
      line.size_snapshot,
      payment.paid_at
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    join lateral (
      select paid.paid_at
      from app.payments paid
      where paid.order_id = orders.id
        and paid.status = 'paid'
        and paid.reconciliation_issue is null
        and paid.package_snapshot_id = orders.active_package_snapshot_id
      order by paid.paid_at, paid.id
      limit 1
    ) payment on true
    where line.id = '64000000-0000-4000-8000-000000000001';

    insert into app.inventory_allocation_events(
      allocation_id,
      event_type,
      previous_status,
      next_status,
      reason_code,
      source_type,
      source_id,
      idempotency_key,
      safe_context
    ) values (
      '6b000000-0000-4000-8000-000000000002',
      'reserved',
      null,
      'reserved',
      'browser.fixture',
      'browser_fixture',
      '63000000-0000-4000-8000-000000000001',
      repeat('d', 64),
      '{}'::jsonb
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
      safe_context
    )
    select
      allocation.season_id,
      allocation.article_id,
      allocation.article_variant_id,
      'opening_balance',
      allocation.quantity,
      allocation.quantity,
      0,
      allocation.id,
      'browser_fixture',
      allocation.order_id,
      'browser.fixture',
      repeat('c', 64),
      '{}'::jsonb
    from app.inventory_allocations allocation
    where allocation.id = '6b000000-0000-4000-8000-000000000002';

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

    -- Disposable browser database only: exercise the already-tested
    -- post-cutover scanner surface without weakening the production gate.
    insert into private.release_cutovers(key)
    values ('allocation_qr_v2')
    on conflict (key) do nothing;
    update app.release_feature_flags
    set enabled = true, updated_at = timezone('utc', now())
    where key in ('allocation_qr_v2', 'scanner_pwa_v2');
  \`);`,
);
const packageManagerServerSpawn = `    appProcess = spawn("pnpm", ["start", "--hostname", host, "--port", String(port)], {`;
const directServerSpawn = `    appProcess = spawn(process.execPath, [
      path.resolve("node_modules/next/dist/bin/next"),
      "start",
      "--hostname",
      host,
      "--port",
      String(port),
    ], {`;
if (!generatedSource.includes(packageManagerServerSpawn)) {
  throw new Error("Het browserharnas kon de appserver niet procesgroepvast starten.");
}
generatedSource = generatedSource.replace(
  packageManagerServerSpawn,
  directServerSpawn,
);
const issuanceStart = generatedSource.indexOf(
  "async function verifyStockAndIssuanceSurfaces",
);
const issuanceEnd = generatedSource.indexOf(
  "async function verifyOperationsSprint",
  Math.max(0, issuanceStart),
);
if (issuanceEnd < 0) {
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
generatedSource = issuanceStart >= 0
  ? `${generatedSource.slice(0, issuanceStart)}${scannerPwaReview}\n\n${generatedSource.slice(issuanceEnd)}`
  : `${generatedSource.slice(0, issuanceEnd)}${scannerPwaReview}\n\n${generatedSource.slice(issuanceEnd)}`;
const scannerReviewCall = "  await verifyStockAndIssuanceSurfaces(page, screenshotDir);";
if (!generatedSource.includes(scannerReviewCall)) {
  const memberReviewCall = "  await verifyMemberOverview(page, screenshotDir);";
  if (!generatedSource.includes(memberReviewCall)) {
    throw new Error("De scanner-PWA-browsercontrole kon niet worden ingevoegd.");
  }
  generatedSource = generatedSource.replace(
    memberReviewCall,
    `${memberReviewCall}\n${scannerReviewCall}`,
  );
}
for (const [needle, replacement] of [
  [
    "  await verifyMobileNavigation(page);",
    [
      "  await verifyMobileNavigation(page);",
      '  await page.getByRole("heading", { name: "Leden", exact: true }).waitFor({ state: "visible", timeout: 5_000 });',
      '  await assertNoAutomatedA11yViolations(page, "backoffice_mobile");',
      '  await assertKeyboardFocusVisible(page, "backoffice_mobile");',
      '  await assertReducedMotionHonored(page, "backoffice_mobile");',
    ].join("\n"),
  ],
  [
    "  await verifyMemberOverview(page, screenshotDir);",
    [
      "  await verifyMemberOverview(page, screenshotDir);",
      '  await assertNoAutomatedA11yViolations(page, "member_overview");',
    ].join("\n"),
  ],
  [
    "  await verifyOperationsSprint(page, screenshotDir);",
    [
      "  await verifyOperationsSprint(page, screenshotDir);",
      '  await assertNoAutomatedA11yViolations(page, "operations");',
    ].join("\n"),
  ],
  [
    "  await verifyProviderSprint(page, screenshotDir);",
    [
      "  await verifyProviderSprint(page, screenshotDir);",
      '  await assertNoAutomatedA11yViolations(page, "mail_and_payments");',
    ].join("\n"),
  ],
  [
    "  await verifyReleaseHardening(page, local.DB_URL, screenshotDir);",
    [
      "  await verifyReleaseHardening(page, local.DB_URL, screenshotDir);",
      '  await assertNoAutomatedA11yViolations(page, "settings_and_audit");',
    ].join("\n"),
  ],
]) {
  if (!generatedSource.includes(needle)) {
    throw new Error(`A11y-injectiepunt ontbreekt: ${needle}`);
  }
  generatedSource = generatedSource.replace(needle, replacement);
}

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
