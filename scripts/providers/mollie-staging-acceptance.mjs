import assert from "node:assert/strict";
import { createHash, createHmac, randomBytes, randomInt } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

export const STAGING_APP_BASE_URL = "https://staging-duindorp.dgwebservices.nl";
export const STAGING_SUPABASE_PROJECT_REF = "dxbdjtbyghsovlrdcwcr";
export const MOLLIE_API_BASE_URL = "https://api.mollie.com";
export const ACCEPTANCE_CONFIRMATION = "STAGING-MOLLIE-TESTMODE";

const releaseShaPattern = /^[a-f0-9]{40}$/;
const profileIdPattern = /^pfl_[A-Za-z0-9]+$/;
const providerPaymentIdPattern = /^tr_[A-Za-z0-9]+$/;
const runMarkerPattern = /^[0-9]{1,20}-[0-9]{1,6}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function fail(code) {
  throw new Error(code);
}

function assertDbTarget(dbUrlValue, projectRef) {
  let dbUrl;
  try {
    dbUrl = new URL(dbUrlValue);
  } catch {
    fail("MOLLIE_ACCEPTANCE_DATABASE_URL_INVALID");
  }
  if (!["postgres:", "postgresql:"].includes(dbUrl.protocol) || !dbUrl.hostname || !dbUrl.username) {
    fail("MOLLIE_ACCEPTANCE_DATABASE_URL_INVALID");
  }
  const sslMode = dbUrl.searchParams.get("sslmode");
  if (sslMode && !["require", "verify-ca", "verify-full"].includes(sslMode)) {
    fail("MOLLIE_ACCEPTANCE_DATABASE_TLS_REQUIRED");
  }

  const directHost = `db.${projectRef}.supabase.co`;
  const poolerTarget = dbUrl.hostname.endsWith(".pooler.supabase.com")
    && decodeURIComponent(dbUrl.username).endsWith(`.${projectRef}`);
  if (dbUrl.hostname !== directHost && !poolerTarget) fail("MOLLIE_ACCEPTANCE_DATABASE_TARGET_MISMATCH");
}

export function validateTargetConfiguration(env) {
  if (env.APP_BASE_URL !== STAGING_APP_BASE_URL) fail("MOLLIE_ACCEPTANCE_STAGING_HOST_REQUIRED");
  if (env.EXPECTED_STAGING_SUPABASE_PROJECT_REF !== STAGING_SUPABASE_PROJECT_REF) {
    fail("MOLLIE_ACCEPTANCE_PROJECT_REF_MISMATCH");
  }
  if (!runMarkerPattern.test(env.MOLLIE_ACCEPTANCE_RUN_ID ?? "")) fail("MOLLIE_ACCEPTANCE_RUN_ID_INVALID");
  assertDbTarget(env.SUPABASE_DB_URL ?? "", STAGING_SUPABASE_PROJECT_REF);
  return {
    appBaseUrl: STAGING_APP_BASE_URL,
    projectRef: STAGING_SUPABASE_PROJECT_REF,
    dbUrl: env.SUPABASE_DB_URL,
    runMarker: env.MOLLIE_ACCEPTANCE_RUN_ID,
  };
}

export function validateConfiguration(env) {
  const target = validateTargetConfiguration(env);
  if (!releaseShaPattern.test(env.RELEASE_SHA ?? "")) fail("MOLLIE_ACCEPTANCE_RELEASE_SHA_INVALID");
  if (!env.MOLLIE_API_KEY?.startsWith("test_") || env.MOLLIE_API_KEY.startsWith("live_")) {
    fail("MOLLIE_ACCEPTANCE_TEST_KEY_REQUIRED");
  }
  if (!profileIdPattern.test(env.MOLLIE_PROFILE_ID ?? "")) fail("MOLLIE_ACCEPTANCE_PROFILE_ID_INVALID");
  if ((env.SUPABASE_SERVICE_ROLE_KEY ?? "").length < 40) fail("MOLLIE_ACCEPTANCE_SERVICE_ROLE_KEY_INVALID");
  if ((env.PARENT_TOKEN_PEPPER ?? "").length < 32) fail("MOLLIE_ACCEPTANCE_PEPPER_INVALID");
  if (env.MOLLIE_ACCEPTANCE_CONFIRMATION !== ACCEPTANCE_CONFIRMATION) {
    fail("MOLLIE_ACCEPTANCE_CONFIRMATION_REQUIRED");
  }
  return {
    ...target,
    releaseSha: env.RELEASE_SHA,
    apiKey: env.MOLLIE_API_KEY,
    profileId: env.MOLLIE_PROFILE_ID,
    serviceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY,
    pepper: env.PARENT_TOKEN_PEPPER,
  };
}

function uuidFromMarker(runMarker, label) {
  const bytes = createHash("sha256").update(`duindorp-mollie-acceptance:${runMarker}:${label}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function createFixtureIdentity(runMarker) {
  if (!runMarkerPattern.test(runMarker)) fail("MOLLIE_ACCEPTANCE_RUN_ID_INVALID");
  const shortMarker = runMarker.replace("-", "a");
  const relationPrefix = `MOLLIE-${shortMarker}`;
  return {
    paidMemberId: uuidFromMarker(runMarker, "paid-member"),
    mismatchMemberId: uuidFromMarker(runMarker, "mismatch-member"),
    paidOrderId: uuidFromMarker(runMarker, "paid-order"),
    mismatchOrderId: uuidFromMarker(runMarker, "mismatch-order"),
    parentAccountId: uuidFromMarker(runMarker, "parent-account"),
    parentSessionId: uuidFromMarker(runMarker, "parent-session"),
    wrongMetadataPaymentId: uuidFromMarker(runMarker, "wrong-metadata-payment"),
    paidRelation: `${relationPrefix}-P`,
    mismatchRelation: `${relationPrefix}-M`,
    fixtureEmail: `mollie-acceptance+${shortMarker}@example.invalid`,
  };
}

function fixtureVariables(identity, parentTokenHash) {
  const variables = {
    paid_member_id: identity.paidMemberId,
    mismatch_member_id: identity.mismatchMemberId,
    paid_order_id: identity.paidOrderId,
    mismatch_order_id: identity.mismatchOrderId,
    parent_account_id: identity.parentAccountId,
    parent_session_id: identity.parentSessionId,
    paid_relation: identity.paidRelation,
    mismatch_relation: identity.mismatchRelation,
    fixture_email: identity.fixtureEmail,
  };
  if (parentTokenHash) variables.parent_token_hash = parentTokenHash;
  return variables;
}

function validatePsqlVariable(name, value) {
  if (!/^[a-z_]+$/.test(name) || typeof value !== "string" || value.length > 320 || /[\n\r\\]/.test(value)) {
    fail("MOLLIE_ACCEPTANCE_FIXTURE_VALUE_INVALID");
  }
}

export function createPsqlRunner(dbUrl, spawnImpl = spawnSync) {
  const parsedDbUrl = new URL(dbUrl);
  const databaseName = decodeURIComponent(parsedDbUrl.pathname.replace(/^\//, ""));
  if (!databaseName) fail("MOLLIE_ACCEPTANCE_DATABASE_URL_INVALID");
  const psqlEnvironment = {
    ...process.env,
    // libpq accepts a complete connection URI as PGDATABASE. Keeping the URI
    // intact preserves Supabase pooler routing and connection options while
    // keeping credentials out of process arguments and logs.
    PGDATABASE: dbUrl,
    PGCONNECT_TIMEOUT: "15",
  };
  for (const name of ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGSSLMODE"]) {
    delete psqlEnvironment[name];
  }
  return ({ file, sql, variables = {} }) => {
    const args = ["-X", "--no-psqlrc", "--quiet", "--tuples-only", "--no-align", "--set", "ON_ERROR_STOP=1"];
    for (const [name, value] of Object.entries(variables)) {
      validatePsqlVariable(name, value);
      args.push("--set", `${name}=${value}`);
    }
    if (file) args.push("--file", file);
    else args.push("--file", "-");
    const result = spawnImpl("psql", args, {
      env: psqlEnvironment,
      input: sql,
      encoding: "utf8",
      maxBuffer: 256 * 1024,
      timeout: 45_000,
    });
    if (result.status !== 0) fail(file ? "MOLLIE_ACCEPTANCE_FIXTURE_SQL_FAILED" : "MOLLIE_ACCEPTANCE_ASSERTION_SQL_FAILED");
    return (result.stdout ?? "").trim();
  };
}

function fixturePaths() {
  return {
    prepare: fileURLToPath(new URL("./mollie-staging-fixture.sql", import.meta.url)),
    cleanup: fileURLToPath(new URL("./mollie-staging-cleanup.sql", import.meta.url)),
  };
}

function parseJsonResponseText(text, code) {
  if (text.length > 100_000) fail(code);
  try {
    return JSON.parse(text);
  } catch {
    fail(code);
  }
}

async function readJsonResponse(response, code) {
  const text = await response.text();
  return parseJsonResponseText(text, code);
}

export function validateCheckoutUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    fail("MOLLIE_ACCEPTANCE_CHECKOUT_URL_INVALID");
  }
  if (url.protocol !== "https:" || (url.hostname !== "mollie.com" && !url.hostname.endsWith(".mollie.com"))) {
    fail("MOLLIE_ACCEPTANCE_CHECKOUT_URL_INVALID");
  }
  return url.toString();
}

export async function providerRequest(config, path, options = {}, fetchImpl = fetch) {
  if (!path.startsWith("/v2/") || path.includes("..") || config.apiKey?.startsWith("live_")) {
    fail("MOLLIE_ACCEPTANCE_PROVIDER_REQUEST_INVALID");
  }
  const response = await fetchImpl(`${MOLLIE_API_BASE_URL}${path}`, {
    method: options.method ?? "GET",
    headers: {
      Authorization: `Bearer ${config.apiKey}`,
      Accept: "application/hal+json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.idempotencyKey ? { "Idempotency-Key": options.idempotencyKey } : {}),
    },
    ...(options.body ? { body: JSON.stringify(options.body) } : {}),
    redirect: "error",
    signal: AbortSignal.timeout(20_000),
  });
  const acceptedStatuses = options.acceptedStatuses ?? [200];
  if (!acceptedStatuses.includes(response.status)) fail(`MOLLIE_ACCEPTANCE_PROVIDER_HTTP_${response.status}`);
  return readJsonResponse(response, "MOLLIE_ACCEPTANCE_PROVIDER_RESPONSE_INVALID");
}

async function assertRelease(config, fetchImpl) {
  const response = await fetchImpl(`${config.appBaseUrl}/api/health`, {
    headers: { Accept: "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(20_000),
  });
  if (response.status !== 200) fail("MOLLIE_ACCEPTANCE_STAGING_HEALTH_FAILED");
  const health = await readJsonResponse(response, "MOLLIE_ACCEPTANCE_STAGING_HEALTH_INVALID");
  if (health?.status !== "ok" || health?.service !== "duindorpteneu"
    || health?.environment !== "staging" || health?.revision !== config.releaseSha) {
    fail("MOLLIE_ACCEPTANCE_RELEASE_MISMATCH");
  }
}

async function assertProfile(config, fetchImpl) {
  const profile = await providerRequest(config, "/v2/profiles/me", {}, fetchImpl);
  if (profile?.id !== config.profileId) fail("MOLLIE_ACCEPTANCE_PROFILE_MISMATCH");
}

const stagingParentRpcNames = new Set([
  "create_parent_otp",
  "consume_parent_otp",
  "create_parent_session",
  "link_parent_member",
]);

function safeRemoteCode(value) {
  return typeof value === "string" && /^[A-Z0-9_]{2,32}$/.test(value) ? value : "UNKNOWN";
}

export async function stagingParentRpc(config, rpcName, payload, fetchImpl = fetch) {
  if (!stagingParentRpcNames.has(rpcName)) fail("MOLLIE_ACCEPTANCE_PARENT_RPC_INVALID");
  const response = await fetchImpl(`https://${config.projectRef}.supabase.co/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      apikey: config.serviceRoleKey,
      Authorization: `Bearer ${config.serviceRoleKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
    redirect: "error",
    signal: AbortSignal.timeout(20_000),
  });
  const text = await response.text();
  if (!response.ok) {
    let code = "UNKNOWN";
    try {
      code = safeRemoteCode(parseJsonResponseText(text, "MOLLIE_ACCEPTANCE_PARENT_RPC_RESPONSE_INVALID")?.code);
    } catch {
      // Never reflect a provider body, fixture value or credential in acceptance output.
    }
    fail(`MOLLIE_ACCEPTANCE_PARENT_RPC_${rpcName.toUpperCase()}_HTTP_${response.status}_${code}`);
  }
  return parseJsonResponseText(text, "MOLLIE_ACCEPTANCE_PARENT_RPC_RESPONSE_INVALID");
}

async function createParentAuthFixture(config, identity, parentTokenHash, fetchImpl) {
  const code = randomInt(100000, 1000000).toString();
  const codeHash = createHmac("sha256", config.pepper).update(code).digest("hex");
  const parentAccountId = await stagingParentRpc(config, "create_parent_otp", {
    p_email: identity.fixtureEmail,
    p_code_hash: codeHash,
    p_expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
  }, fetchImpl);
  if (!uuidPattern.test(parentAccountId ?? "")) fail("MOLLIE_ACCEPTANCE_PARENT_OTP_CREATE_INVALID");
  identity.parentAccountId = parentAccountId;

  const consumed = await stagingParentRpc(config, "consume_parent_otp", {
    p_email: identity.fixtureEmail,
    p_code_hash: codeHash,
  }, fetchImpl);
  if (consumed?.status !== "verified" || consumed?.parentAccountId !== parentAccountId) {
    fail("MOLLIE_ACCEPTANCE_PARENT_OTP_CONSUME_INVALID");
  }

  const parentSessionId = await stagingParentRpc(config, "create_parent_session", {
    p_parent_account_id: parentAccountId,
    p_token_hash: parentTokenHash,
    p_expires_at: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
  }, fetchImpl);
  if (!uuidPattern.test(parentSessionId ?? "")) fail("MOLLIE_ACCEPTANCE_PARENT_SESSION_CREATE_INVALID");

  for (const memberId of [identity.paidMemberId, identity.mismatchMemberId]) {
    const linked = await stagingParentRpc(config, "link_parent_member", {
      p_token_hash: parentTokenHash,
      p_member_id: memberId,
    }, fetchImpl);
    if (!uuidPattern.test(linked?.linkId ?? "") || linked?.memberId !== memberId) {
      fail("MOLLIE_ACCEPTANCE_PARENT_LINK_INVALID");
    }
  }
  return { parentAccountId, parentSessionId };
}

function assertTestPayment(config, payment, expectedProviderPaymentId) {
  if (payment?.id !== expectedProviderPaymentId || payment?.mode !== "test"
    || payment?.profileId !== config.profileId || payment?.amount?.currency !== "EUR") {
    fail("MOLLIE_ACCEPTANCE_TEST_PAYMENT_INVALID");
  }
  return payment;
}

async function createCheckout(config, orderId, parentSessionToken, fetchImpl) {
  assert.match(orderId, uuidPattern);
  const body = JSON.stringify({ orderId });
  const response = await fetchImpl(`${config.appBaseUrl}/api/payments/mollie/create`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "Content-Length": String(Buffer.byteLength(body)),
      Origin: config.appBaseUrl,
      Referer: `${config.appBaseUrl}/leden`,
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
      Cookie: `duindorp_parent_session=${parentSessionToken}`,
    },
    body,
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  if (response.status !== 200) {
    const phaseValue = response.headers.get("x-duindorp-parent-session-phase") ?? "unknown";
    const phase = /^[a-z_]{2,32}$/.test(phaseValue) ? phaseValue.toUpperCase() : "UNKNOWN";
    fail(`MOLLIE_ACCEPTANCE_APP_CREATE_HTTP_${response.status}_${phase}`);
  }
  const payload = await readJsonResponse(response, "MOLLIE_ACCEPTANCE_APP_CREATE_RESPONSE_INVALID");
  return validateCheckoutUrl(payload?.checkoutUrl);
}

async function visible(locator) {
  try {
    return await locator.count() > 0 && await locator.first().isVisible();
  } catch {
    return false;
  }
}

export async function choosePaidOnHostedTestPage(page) {
  const exactPaid = /^(paid|betaald)$/i;
  const radio = page.getByRole("radio", { name: exactPaid });
  let selected = false;
  let submitted = false;
  if (await visible(radio)) {
    await radio.first().check();
    selected = true;
  }

  if (!selected) {
    const selects = page.locator("select");
    for (let index = 0; index < await selects.count(); index += 1) {
      const select = selects.nth(index);
      const options = await select.locator("option").allTextContents();
      const paidIndex = options.findIndex((label) => exactPaid.test(label.trim()));
      if (paidIndex >= 0) {
        await select.selectOption({ index: paidIndex });
        selected = true;
        break;
      }
    }
  }

  if (!selected) {
    const button = page.getByRole("button", { name: exactPaid });
    if (await visible(button)) {
      await button.first().click();
      selected = true;
      submitted = true;
    }
  }
  if (!selected) fail("MOLLIE_HOSTED_TEST_PAID_CONTROL_NOT_FOUND");

  if (!submitted) {
    const submit = page.getByRole("button", { name: /^(continue|doorgaan|bevestigen|submit|betalen)$/i });
    if (!await visible(submit)) fail("MOLLIE_HOSTED_TEST_SUBMIT_CONTROL_NOT_FOUND");
    await submit.first().click();
  }
}

export async function completeHostedTestCheckout(checkoutUrl, dependencies = {}) {
  const safeCheckoutUrl = validateCheckoutUrl(checkoutUrl);
  let browser;
  try {
    const launch = dependencies.launch ?? (async () => {
      const { chromium } = await import("@playwright/test");
      return chromium.launch({ headless: true });
    });
    browser = await launch();
    const context = await browser.newContext({ locale: "en-US" });
    const page = await context.newPage();
    await page.goto(safeCheckoutUrl, { waitUntil: "domcontentloaded", timeout: 30_000 });
    await choosePaidOnHostedTestPage(page);
    await page.waitForTimeout(1_500);
  } catch {
    fail("MOLLIE_HOSTED_CHECKOUT_AUTOMATION_FAILED");
  } finally {
    await browser?.close().catch(() => undefined);
  }
}

export async function postPublicWebhook(config, providerPaymentId, fetchImpl = fetch) {
  if (!providerPaymentIdPattern.test(providerPaymentId)) fail("MOLLIE_ACCEPTANCE_PROVIDER_PAYMENT_ID_INVALID");
  const body = new URLSearchParams({ id: providerPaymentId }).toString();
  const response = await fetchImpl(`${config.appBaseUrl}/api/webhooks/mollie`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Content-Length": String(Buffer.byteLength(body)),
    },
    body,
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  if (response.status !== 200) fail(`MOLLIE_ACCEPTANCE_WEBHOOK_HTTP_${response.status}`);
  const payload = await readJsonResponse(response, "MOLLIE_ACCEPTANCE_WEBHOOK_RESPONSE_INVALID");
  if (payload?.received !== true) fail("MOLLIE_ACCEPTANCE_WEBHOOK_REJECTED");
}

export async function postConcurrentReplays(config, providerPaymentId, fetchImpl = fetch) {
  await Promise.all([
    postPublicWebhook(config, providerPaymentId, fetchImpl),
    postPublicWebhook(config, providerPaymentId, fetchImpl),
    postPublicWebhook(config, providerPaymentId, fetchImpl),
  ]);
}

function queryJson(psql, sql, variables) {
  const raw = psql({ sql, variables });
  const line = raw.split("\n").map((value) => value.trim()).filter(Boolean).at(-1);
  return parseJsonResponseText(line ?? "", "MOLLIE_ACCEPTANCE_ASSERTION_RESPONSE_INVALID");
}

function paymentBinding(psql, orderId) {
  return queryJson(psql, `
    select json_build_object(
      'paymentId', payment.id,
      'providerPaymentId', payment.provider_payment_id,
      'amountCents', payment.amount_cents
    )
    from app.payments payment
    where payment.order_id = :'order_id'::uuid and payment.method = 'mollie'
    order by payment.created_at desc limit 1;
  `, { order_id: orderId });
}

function assertParentSessionFixture(psql, identity, parentSessionId, parentTokenHash) {
  const fixture = queryJson(psql, `
    select json_build_object(
      'rowExists', count(*) = 1,
      'hashMatches', coalesce(bool_and(session.token_hash = :'parent_token_hash'), false),
      'notRevoked', coalesce(bool_and(session.revoked_at is null), false),
      'notExpired', coalesce(bool_and(session.expires_at > timezone('utc', now())), false),
      'rpcVisible', exists(
        select 1 from public.get_parent_session(:'parent_token_hash') resolved
        where resolved.parent_account_id = :'parent_account_id'::uuid
      )
    )
    from private.parent_sessions session
    where session.id = :'parent_session_id'::uuid;
  `, {
    parent_account_id: identity.parentAccountId,
    parent_session_id: parentSessionId,
    parent_token_hash: parentTokenHash,
  });
  for (const [field, code] of [
    ["rowExists", "ROW_MISSING"],
    ["hashMatches", "HASH_MISMATCH"],
    ["notRevoked", "REVOKED"],
    ["notExpired", "EXPIRED"],
    ["rpcVisible", "RPC_NOT_VISIBLE"],
  ]) {
    if (fixture?.[field] !== true) fail(`MOLLIE_ACCEPTANCE_PARENT_FIXTURE_${code}`);
  }
}

function paymentSnapshot(psql, orderId) {
  return queryJson(psql, `
    select json_build_object(
      'paymentStatus', payment.status::text,
      'reconciliationIssue', payment.reconciliation_issue,
      'paidPayments', (select count(*) from app.payments p where p.order_id = :'order_id'::uuid and p.status = 'paid'),
      'activeQr', (select count(*) from private.qr_tokens qr where qr.order_id = :'order_id'::uuid and qr.active),
      'allQr', (select count(*) from private.qr_tokens qr where qr.order_id = :'order_id'::uuid),
      'paymentEmailJobs', (select count(*) from private.email_jobs job where job.order_id = :'order_id'::uuid and job.template_key = 'payment_received'),
      'paidEvents', (select count(*) from private.payment_events event where event.payment_id = payment.id and event.event_type = 'paid'),
      'refundEvents', (select count(*) from private.payment_events event where event.payment_id = payment.id and event.event_type = 'refunded'),
      'mismatchEvents', (select count(*) from private.payment_events event where event.payment_id = payment.id and event.event_type = 'mismatch'),
      'paidAudits', (select count(*) from app.audit_logs audit where audit.entity_id = :'order_id'::uuid and audit.action = 'payment.mollie.paid'),
      'refundAudits', (select count(*) from app.audit_logs audit where audit.entity_id = :'order_id'::uuid and audit.action = 'payment.mollie.refunded'),
      'manualReviewAudits', (select count(*) from app.audit_logs audit where audit.entity_id = payment.id and audit.action = 'payment.mollie.manual_review')
    )
    from app.payments payment
    where payment.order_id = :'order_id'::uuid and payment.method = 'mollie'
    order by payment.created_at desc limit 1;
  `, { order_id: orderId });
}

async function waitForProvider(config, providerPaymentId, predicate, dependencies) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const payment = assertTestPayment(config,
      await providerRequest(config, `/v2/payments/${providerPaymentId}`, {}, dependencies.fetchImpl),
      providerPaymentId);
    if (predicate(payment)) return payment;
    await dependencies.sleep(2_000);
  }
  fail("MOLLIE_ACCEPTANCE_PROVIDER_STATE_TIMEOUT");
}

function assertPaidSnapshot(snapshot) {
  assert.equal(snapshot.paymentStatus, "paid");
  assert.equal(snapshot.reconciliationIssue, null);
  assert.equal(Number(snapshot.paidPayments), 1);
  assert.equal(Number(snapshot.activeQr), 1);
  assert.equal(Number(snapshot.allQr), 1);
  assert.equal(Number(snapshot.paymentEmailJobs), 1);
  assert.equal(Number(snapshot.paidEvents), 1);
  assert.equal(Number(snapshot.paidAudits), 1);
}

function assertMismatchSnapshot(snapshot) {
  assert.notEqual(snapshot.paymentStatus, "paid");
  assert.equal(Number(snapshot.paidPayments), 0);
  assert.equal(Number(snapshot.activeQr), 0);
  assert.equal(Number(snapshot.allQr), 0);
  assert.equal(Number(snapshot.paymentEmailJobs), 0);
  assert.ok(typeof snapshot.reconciliationIssue === "string" && snapshot.reconciliationIssue.includes("MISMATCH"));
  assert.ok(Number(snapshot.mismatchEvents) >= 1);
  assert.ok(Number(snapshot.manualReviewAudits) >= 1);
}

function assertRefundSnapshot(snapshot) {
  assert.equal(snapshot.paymentStatus, "refunded");
  assert.equal(Number(snapshot.paidPayments), 0);
  assert.equal(Number(snapshot.activeQr), 0);
  assert.equal(Number(snapshot.allQr), 1);
  assert.equal(Number(snapshot.paymentEmailJobs), 1);
  assert.equal(Number(snapshot.paidEvents), 1);
  assert.equal(Number(snapshot.refundEvents), 1);
  assert.equal(Number(snapshot.refundAudits), 1);
}

export async function runAcceptance(rawEnv = process.env, overrides = {}) {
  const config = validateConfiguration(rawEnv);
  const identity = createFixtureIdentity(config.runMarker);
  const psql = overrides.psql ?? createPsqlRunner(config.dbUrl);
  const fetchImpl = overrides.fetchImpl ?? fetch;
  const sleep = overrides.sleep ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
  const completeCheckout = overrides.completeCheckout ?? completeHostedTestCheckout;
  const parentSessionToken = randomBytes(32).toString("base64url");
  const parentTokenHash = createHmac("sha256", config.pepper).update(parentSessionToken).digest("hex");
  const variables = fixtureVariables(identity, parentTokenHash);
  const paths = fixturePaths();
  let fixturePrepared = false;

  await assertRelease(config, fetchImpl);
  await assertProfile(config, fetchImpl);
  try {
    psql({ file: paths.prepare, variables });
    fixturePrepared = true;

    console.log("Mollie stagingfixture is geïsoleerd voorbereid.");
    const parentAuth = await createParentAuthFixture(config, identity, parentTokenHash, fetchImpl);
    const parentSessionId = parentAuth.parentSessionId;
    assertParentSessionFixture(psql, identity, parentSessionId, parentTokenHash);
    console.log("Oudersessiefixture is actief en via het databasecontract zichtbaar.");
    const paidCheckoutUrl = await createCheckout(config, identity.paidOrderId, parentSessionToken, fetchImpl);
    const paidBinding = paymentBinding(psql, identity.paidOrderId);
    if (!uuidPattern.test(paidBinding?.paymentId ?? "") || !providerPaymentIdPattern.test(paidBinding?.providerPaymentId ?? "")
      || paidBinding?.amountCents !== 100) fail("MOLLIE_ACCEPTANCE_PAID_BINDING_INVALID");

    await completeCheckout(paidCheckoutUrl);
    await waitForProvider(config, paidBinding.providerPaymentId, (payment) => payment?.status === "paid", { fetchImpl, sleep });
    await postPublicWebhook(config, paidBinding.providerPaymentId, fetchImpl);
    const paidSnapshot = paymentSnapshot(psql, identity.paidOrderId);
    assertPaidSnapshot(paidSnapshot);
    console.log("Paid-scenario is via de publieke stagingwebhook gevalideerd.");

    await postConcurrentReplays(config, paidBinding.providerPaymentId, fetchImpl);
    assert.deepEqual(paymentSnapshot(psql, identity.paidOrderId), paidSnapshot);
    console.log("Drie gelijktijdige webhookreplays bleven idempotent.");

    const mismatchCheckoutUrl = await createCheckout(config, identity.mismatchOrderId, parentSessionToken, fetchImpl);
    const mismatchBinding = paymentBinding(psql, identity.mismatchOrderId);
    if (!uuidPattern.test(mismatchBinding?.paymentId ?? "") || !providerPaymentIdPattern.test(mismatchBinding?.providerPaymentId ?? "")
      || mismatchBinding?.amountCents !== 100) fail("MOLLIE_ACCEPTANCE_MISMATCH_BINDING_INVALID");
    const mismatchProviderPayment = assertTestPayment(config,
      await providerRequest(config, `/v2/payments/${mismatchBinding.providerPaymentId}`, {}, fetchImpl),
      mismatchBinding.providerPaymentId);
    if (!mismatchProviderPayment?.metadata || typeof mismatchProviderPayment.metadata !== "object") {
      fail("MOLLIE_ACCEPTANCE_MISMATCH_METADATA_INVALID");
    }
    await providerRequest(config, `/v2/payments/${mismatchBinding.providerPaymentId}`, {
      method: "PATCH",
      body: { metadata: { ...mismatchProviderPayment.metadata, payment_id: identity.wrongMetadataPaymentId } },
      acceptedStatuses: [200],
    }, fetchImpl);
    await completeCheckout(mismatchCheckoutUrl);
    await waitForProvider(config, mismatchBinding.providerPaymentId, (payment) => payment?.status === "paid", { fetchImpl, sleep });
    await postPublicWebhook(config, mismatchBinding.providerPaymentId, fetchImpl);
    assertMismatchSnapshot(paymentSnapshot(psql, identity.mismatchOrderId));
    console.log("Metadata-afwijking bleef unpaid en zichtbaar voor handmatige review.");

    const paidProviderPayment = assertTestPayment(config,
      await providerRequest(config, `/v2/payments/${paidBinding.providerPaymentId}`, {}, fetchImpl),
      paidBinding.providerPaymentId);
    await providerRequest(config, `/v2/payments/${paidBinding.providerPaymentId}/refunds`, {
      method: "POST",
      idempotencyKey: `duindorp-mollie-acceptance-refund-${config.runMarker}`,
      body: {
        amount: paidProviderPayment.amount,
        description: "Duindorp staging acceptance refund",
        metadata: { acceptance_run: config.runMarker },
      },
      acceptedStatuses: [201],
    }, fetchImpl);
    await waitForProvider(config, paidBinding.providerPaymentId, (payment) => {
      return payment?.amountRefunded?.currency === "EUR" && payment?.amountRefunded?.value === payment?.amount?.value;
    }, { fetchImpl, sleep });
    await postPublicWebhook(config, paidBinding.providerPaymentId, fetchImpl);
    assertRefundSnapshot(paymentSnapshot(psql, identity.paidOrderId));
    console.log("Refund-scenario trok de QR via de publieke stagingwebhook in.");
  } finally {
    if (fixturePrepared) psql({ file: paths.cleanup, variables: fixtureVariables(identity) });
  }
}

export function cleanupAcceptance(rawEnv = process.env, overrides = {}) {
  const config = validateTargetConfiguration(rawEnv);
  const identity = createFixtureIdentity(config.runMarker);
  const psql = overrides.psql ?? createPsqlRunner(config.dbUrl);
  psql({ file: fixturePaths().cleanup, variables: fixtureVariables(identity) });
}

async function main() {
  if (process.argv.includes("--cleanup-only")) {
    cleanupAcceptance();
    console.log("Mollie stagingfixture-cleanup is idempotent uitgevoerd.");
    return;
  }
  await runAcceptance();
  console.log("Mollie stagingacceptatie voor paid, mismatch, replay en refund is geslaagd.");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const code = error instanceof Error && /^[A-Z0-9_:.-]+$/.test(error.message)
      ? error.message
      : "MOLLIE_STAGING_ACCEPTANCE_FAILED";
    console.error(code);
    process.exit(1);
  });
}
