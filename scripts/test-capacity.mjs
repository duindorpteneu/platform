import { execFileSync, spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import net from "node:net";
import { createClient } from "@supabase/supabase-js";

if (process.env.CAPACITY_TEST_DISPOSABLE_DB !== "1") {
  throw new Error(
    "De capaciteitstest vereist een expliciet wegwerpbare lokale database.",
  );
}

const host = "localhost";
const port = 3121;
const baseUrl = `http://${host}:${port}`;
const memberCount = 1_500;
const orderLineCount = 10_000;
const staffSessionCount = 25;
const criticalOrderCount = 40;
const latencyLimitMs = 2_000;
const seasonId = "ca100000-0000-4000-8000-000000000001";
const articleId = "ca200000-0000-4000-8000-000000000001";
const variantId = "ca300000-0000-4000-8000-000000000001";
const hiddenFacts = [
  "CapacityHiddenSurname",
  "capacity-hidden@example.invalid",
  "CAPACITY-HIDDEN-0001",
  "CAPACITY-PRIVATE-TEAM",
  "2012-03-04",
];
const qrPepper = Buffer.alloc(32, 29).toString("base64url");
const qrKeyVersion = 1;
const parentPepper = crypto
  .createHash("sha256")
  .update("duindorp-capacity-parent-pepper", "utf8")
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
      "De capaciteitstest mag uitsluitend tegen de lokale Supabase-database draaien.",
    );
  }
}

function sql(databaseUrl, query, capture = false) {
  const result = spawnSync(
    "psql",
    [databaseUrl, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-At", "-c", query],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  if (result.error) {
    throw new Error("De lokale capaciteitstestquery kon niet starten.");
  }
  if (result.status !== 0) {
    const detail = result.stderr
      .split(/\r?\n/u)
      .find((line) => line.startsWith("ERROR:"))
      ?.replace(/'[^']*'/gu, "[geredigeerd]")
      .slice(0, 240);
    throw new Error(
      detail
        ? `De lokale capaciteitstestquery faalde: ${detail}`
        : "De lokale capaciteitstestquery faalde.",
    );
  }
  return capture ? result.stdout.trim() : "";
}

function resetLocalDatabase() {
  const result = spawnSync("pnpm", ["db:reset"], {
    cwd: process.cwd(),
    env: process.env,
    stdio: "ignore",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error("De wegwerpdatabase kon niet veilig worden gereset.");
  }
}

function fixtureSql() {
  return `
    begin;
    create temporary table capacity_test_scope(id integer);
    create function pg_temp.capacity_uuid(p_value text)
    returns uuid
    language sql
    immutable
    as $capacity_uuid$
      select overlay(
        overlay(md5(p_value) placing '4' from 13)
        placing '8' from 17
      )::uuid;
    $capacity_uuid$;
    insert into app.seasons(id, name, default_amount_cents, status)
    values ('${seasonId}', 'Capaciteitstestseizoen', 12500, 'open');
    update app.app_settings
    set active_season_id = '${seasonId}'
    where id = true;

    insert into app.articles(id, name, code, sort_order, active)
    values (
      '${articleId}',
      'Capaciteitstestproduct',
      'CAPACITY-PRODUCT',
      990,
      true
    );
    insert into app.article_seasons(article_id, season_id)
    values ('${articleId}', '${seasonId}');
    insert into app.article_variants(
      id,
      article_id,
      size,
      sku,
      active
    ) values (
      '${variantId}',
      '${articleId}',
      '152',
      'CAPACITY-PRODUCT-152',
      true
    );
    insert into app.articles(id, name, code, sort_order, active)
    select
      pg_temp.capacity_uuid('capacity-article-' || value),
      'Capaciteitstestproduct ' || value,
      'CAPACITY-PRODUCT-' || value,
      990 + value,
      true
    from generate_series(2, 7) value;
    insert into app.article_seasons(article_id, season_id)
    select
      pg_temp.capacity_uuid('capacity-article-' || value),
      '${seasonId}'
    from generate_series(2, 7) value;
    insert into app.article_variants(
      id,
      article_id,
      size,
      sku,
      active
    )
    select
      pg_temp.capacity_uuid('capacity-variant-' || value),
      pg_temp.capacity_uuid('capacity-article-' || value),
      '152',
      'CAPACITY-PRODUCT-' || value || '-152',
      true
    from generate_series(2, 7) value;

    insert into app.staff_profiles(auth_user_id, display_name, role)
    select
      pg_temp.capacity_uuid('capacity-staff-' || value),
      'Capaciteit beheer ' || value,
      'beheerder'
    from generate_series(1, ${staffSessionCount}) value;

    insert into app.members(
      id,
      relation_number,
      first_name,
      last_name,
      email,
      team,
      gender,
      created_at
    )
    select
      pg_temp.capacity_uuid('capacity-member-' || value),
      case
        when value = 1 then 'CAPACITY-HIDDEN-0001'
        else 'CAPACITY-' || lpad(value::text, 5, '0')
      end,
      'Cap' || value,
      case
        when value = 1 then 'CapacityHiddenSurname'
        else 'Synthetisch' || value
      end,
      case
        when value = 1 then 'capacity-hidden@example.invalid'
        else 'capacity-' || value || '@example.invalid'
      end,
      case
        when value = 1 then 'CAPACITY-PRIVATE-TEAM'
        else 'CAP-' || ((value - 1) % 30 + 1)
      end,
      (
        case when value % 2 = 0 then 'male' else 'female' end
      )::app.gender_code,
      timezone('utc', now()) - interval '2 hours'
    from generate_series(1, ${memberCount}) value;
    update private.member_sensitive_identity
    set date_of_birth = date '2012-03-04'
    where member_id = pg_temp.capacity_uuid('capacity-member-1');

    insert into app.member_orders(
      id,
      member_id,
      season_id,
      amount_due_cents,
      created_at
    )
    select
      pg_temp.capacity_uuid('capacity-order-' || value),
      pg_temp.capacity_uuid('capacity-member-' || value),
      '${seasonId}',
      12500,
      case
        when value <= ${criticalOrderCount}
          then timezone('utc', now()) - interval '90 minutes'
        else timezone('utc', now()) - interval '60 minutes'
      end
    from generate_series(1, ${memberCount}) value;

    insert into app.order_lines(
      id,
      order_id,
      article_variant_id,
      quantity,
      created_at
    )
    select
      pg_temp.capacity_uuid('capacity-line-' || value),
      pg_temp.capacity_uuid(
        'capacity-order-' ||
        case
          when value <= ${criticalOrderCount} then value
          else ${criticalOrderCount + 1}
            + ((value - ${criticalOrderCount + 1}) / 7)
        end
      ),
      case
        when value <= ${criticalOrderCount}
          or 1 + ((value - ${criticalOrderCount + 1}) % 7) = 1
          then '${variantId}'::uuid
        else pg_temp.capacity_uuid(
          'capacity-variant-' ||
          (1 + ((value - ${criticalOrderCount + 1}) % 7))
        )
      end,
      1,
      case
        when value <= ${criticalOrderCount}
          then timezone('utc', now()) - interval '90 minutes'
        else timezone('utc', now()) - interval '60 minutes'
      end
    from generate_series(1, ${orderLineCount}) value;

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
      pg_temp.capacity_uuid('capacity-member-' || value),
      '${seasonId}',
      '${articleId}',
      '${variantId}',
      member_season.id,
      'confirmed',
      'staff',
      timezone('utc', now()) - interval '75 minutes'
    from generate_series(1, ${criticalOrderCount}) value
    join app.member_seasons member_season
      on member_season.member_id =
        pg_temp.capacity_uuid('capacity-member-' || value)
      and member_season.season_id = '${seasonId}'
    on conflict (member_id, season_id, article_id) do update
    set article_variant_id = excluded.article_variant_id,
        member_season_id = excluded.member_season_id,
        selection_status = excluded.selection_status,
        selection_source = excluded.selection_source,
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
    )
    select
      pg_temp.capacity_uuid('capacity-order-' || value),
      'cash',
      'paid',
      12500,
      'capacity-payment-' || value,
      timezone('utc', now()) - interval '80 minutes'
    from generate_series(1, ${criticalOrderCount}) value;

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
      '${seasonId}',
      '${articleId}',
      '${variantId}',
      'opening_balance',
      ${criticalOrderCount},
      'scanner_browser',
      'scanner_browser.capacity_opening',
      encode(
        extensions.digest(
          'capacity-test-opening:${seasonId}',
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
      '${seasonId}',
      '${variantId}',
      'scanner_browser'
    );

    do $capacity$
    begin
      if (select count(*) from app.members
          where relation_number like 'CAPACITY-%') <> ${memberCount}
        or (select count(*) from app.order_lines
          where id in (
            select pg_temp.capacity_uuid('capacity-line-' || value)
            from generate_series(1, ${orderLineCount}) value
          )) <> ${orderLineCount}
        or (select count(*) from app.inventory_allocations
          where season_id = '${seasonId}'
            and status = 'reserved') <> ${criticalOrderCount}
      then
        raise exception 'CAPACITY_FIXTURE_INCOMPLETE';
      end if;
    end
    $capacity$;
    commit;
  `;
}

function deriveLocator(orderId, index) {
  const key = Buffer.from(qrPepper, "base64url");
  const generation = 1;
  const nonce = crypto
    .createHash("sha256")
    .update(`capacity-locator-${index}`, "utf8")
    .digest("base64url");
  const opaque = crypto
    .createHmac("sha256", key)
    .update(
      [
        "duindorp-qr-locator:v2",
        `k${qrKeyVersion}`,
        orderId,
        generation,
        nonce,
      ].join(":"),
      "utf8",
    )
    .digest("base64url");
  const locator = `q2.k${qrKeyVersion}.${opaque}`;
  return {
    generation,
    locator,
    locatorHash: crypto
      .createHmac("sha256", key)
      .update(`duindorp-qr-lookup:v2:${locator}`, "utf8")
      .digest("hex"),
    nonce,
    pepperFingerprint: crypto
      .createHash("sha256")
      .update("duindorp-qr-pepper:v2:", "utf8")
      .update(key)
      .digest("hex"),
  };
}

function deterministicUuid(material) {
  const hexadecimal = crypto
    .createHash("md5")
    .update(material, "utf8")
    .digest("hex");
  const versioned = `${hexadecimal.slice(0, 12)}4${
    hexadecimal.slice(13, 16)
  }8${hexadecimal.slice(17)}`;
  return versioned.replace(
      /^(.{8})(.{4})(.{4})(.{4})(.{12})$/u,
      "$1-$2-$3-$4-$5",
    );
}

function orderId(index) {
  return deterministicUuid(`capacity-order-${index}`);
}

function lineId(index) {
  return deterministicUuid(`capacity-line-${index}`);
}

function staffId(index) {
  return deterministicUuid(`capacity-staff-${index}`);
}

function percentile95(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)];
}

function summary(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return {
    p50: Math.ceil(sorted[Math.ceil(sorted.length * 0.5) - 1] ?? 0),
    p95: Math.ceil(percentile95(sorted) ?? 0),
    max: Math.ceil(sorted.at(-1) ?? 0),
  };
}

async function inBatches(values, batchSize, action) {
  const results = [];
  for (let offset = 0; offset < values.length; offset += batchSize) {
    results.push(
      ...await Promise.all(
        values.slice(offset, offset + batchSize).map(action),
      ),
    );
  }
  return results;
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
      throw new Error("De capaciteitstestapp stopte tijdens het opstarten.");
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
  throw new Error("De capaciteitstestapp werd niet tijdig bereikbaar.");
}

function requestHeaders(sessionToken, json = false) {
  return {
    Cookie: `duindorp_staff_session=${sessionToken}`,
    ...(json ? {
      "Content-Type": "application/json",
      Origin: baseUrl,
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
    } : {}),
  };
}

async function timedRequest(url, options) {
  const startedAt = performance.now();
  const response = await fetch(url, {
    ...options,
    redirect: "manual",
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.text();
  return {
    body,
    durationMs: performance.now() - startedAt,
    status: response.status,
  };
}

function assertLatency(label, values) {
  if (values.length < criticalOrderCount) {
    throw new Error(`${label}: onvoldoende onafhankelijke metingen.`);
  }
  const p95 = percentile95(values);
  if (p95 === undefined || p95 >= latencyLimitMs) {
    throw new Error(`${label}: p95 overschreed twee seconden.`);
  }
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
let appProcess;
let appLogs = "";
const sensitiveValues = [...hiddenFacts, qrPepper, parentPepper];
try {
  resetLocalDatabase();
  sql(local.DB_URL, fixtureSql());

  const sessionTokens = [];
  for (let index = 1; index <= staffSessionCount; index += 1) {
    const session = await admin
      .schema("app")
      .rpc("create_staff_app_session_for_user", {
        p_auth_user_id: staffId(index),
      });
    if (
      session.error
      || typeof session.data?.sessionToken !== "string"
    ) {
      throw new Error("Een capaciteitstestsessie kon niet worden gemaakt.");
    }
    sessionTokens.push(session.data.sessionToken);
    sensitiveValues.push(session.data.sessionToken);
  }

  const orders = [];
  for (let index = 1; index <= criticalOrderCount; index += 1) {
    const currentOrderId = orderId(index);
    const locator = deriveLocator(currentOrderId, index);
    const registered = await admin
      .schema("app")
      .rpc("register_order_qr_locator", {
        p_derivation_nonce: locator.nonce,
        p_generation: locator.generation,
        p_key_version: qrKeyVersion,
        p_locator_hash: locator.locatorHash,
        p_order_id: currentOrderId,
        p_pepper_fingerprint: locator.pepperFingerprint,
        p_request_id: crypto.randomUUID(),
      });
    if (registered.error) {
      throw new Error("Een capaciteitstest-QR kon niet worden geregistreerd.");
    }
    orders.push({
      lineId: lineId(index),
      locator: locator.locator,
      orderId: currentOrderId,
      sessionToken: sessionTokens[(index - 1) % sessionTokens.length],
    });
    sensitiveValues.push(locator.locator);
  }

  appProcess = spawn(
    "pnpm",
    ["start", "--hostname", host, "--port", String(port)],
    {
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
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
  const captureLog = (chunk) => {
    if (appLogs.length < 1_000_000) {
      appLogs += chunk.toString("utf8").slice(
        0,
        1_000_000 - appLogs.length,
      );
    }
  };
  appProcess.stdout.on("data", captureLog);
  appProcess.stderr.on("data", captureLog);
  await waitForApp(appProcess);

  for (let index = 0; index < 5; index += 1) {
    const warmup = await timedRequest(
      `${baseUrl}/backoffice/leden`,
      { headers: requestHeaders(sessionTokens[0]) },
    );
    if (warmup.status !== 200) {
      throw new Error("De capaciteitswarmup werd geweigerd.");
    }
  }

  const pageMeasurements = await Promise.all(
    sessionTokens.map((sessionToken) =>
      timedRequest(
        `${baseUrl}/backoffice/leden`,
        { headers: requestHeaders(sessionToken) },
      )),
  );
  if (pageMeasurements.some((measurement) => measurement.status !== 200)) {
    throw new Error("Niet alle 25 gelijktijdige staffsessies slaagden.");
  }
  const pageLatencies = pageMeasurements.map(
    (measurement) => measurement.durationMs,
  );
  if ((percentile95(pageLatencies) ?? Infinity) >= latencyLimitMs) {
    throw new Error("Normale staffinteractie overschreed p95 twee seconden.");
  }

  const exchangeMeasurements = await inBatches(
    orders,
    staffSessionCount,
    async (order) => {
      const requestId = crypto.randomUUID();
      const result = await timedRequest(
        `${baseUrl}/api/fulfilment/exchange`,
        {
          method: "POST",
          headers: requestHeaders(order.sessionToken, true),
          body: JSON.stringify({
            locator: order.locator,
            requestId,
          }),
        },
      );
      if (result.status !== 200) {
        throw new Error("Een QR-exchange in de capaciteitstest mislukte.");
      }
      const parsed = JSON.parse(result.body);
      if (
        parsed.status !== "found"
        || typeof parsed.scanGrant !== "string"
        || parsed.lines?.length !== 1
        || hiddenFacts.some((fact) => result.body.includes(fact))
      ) {
        throw new Error("Een QR-exchange gaf onveilige of onvolledige data.");
      }
      sensitiveValues.push(parsed.scanGrant);
      return {
        ...order,
        durationMs: result.durationMs,
        scanGrant: parsed.scanGrant,
      };
    },
  );
  const exchangeLatencies = exchangeMeasurements.map(
    (measurement) => measurement.durationMs,
  );
  assertLatency("QR-exchange", exchangeLatencies);

  const commitMeasurements = await inBatches(
    exchangeMeasurements,
    staffSessionCount,
    async (order) => {
      const result = await timedRequest(
        `${baseUrl}/api/fulfilment/commit`,
        {
          method: "POST",
          headers: requestHeaders(order.sessionToken, true),
          body: JSON.stringify({
            orderLineIds: [order.lineId],
            requestId: crypto.randomUUID(),
            scanGrant: order.scanGrant,
          }),
        },
      );
      if (result.status !== 201) {
        throw new Error("Een fulfilmentcommit in de capaciteitstest mislukte.");
      }
      const parsed = JSON.parse(result.body);
      if (
        parsed.status !== "completed"
        || parsed.issuedLines !== 1
        || parsed.reused !== false
      ) {
        throw new Error("Een fulfilmentcommit gaf een onjuist resultaat.");
      }
      return result.durationMs;
    },
  );
  assertLatency("Fulfilmentcommit", commitMeasurements);

  const committed = JSON.parse(sql(
    local.DB_URL,
    `
      select jsonb_build_object(
        'members', (
          select count(*) from app.members
          where relation_number like 'CAPACITY-%'
        ),
        'lines', (
          select count(*) from app.order_lines
          where id in (
            select overlay(
              overlay(md5('capacity-line-' || value) placing '4' from 13)
              placing '8' from 17
            )::uuid
            from generate_series(1, ${orderLineCount}) value
          )
        ),
        'sessions', (
          select count(*) from private.staff_sessions
          where auth_user_id in (
            select overlay(
              overlay(md5('capacity-staff-' || value) placing '4' from 13)
              placing '8' from 17
            )::uuid
            from generate_series(1, ${staffSessionCount}) value
          )
        ),
        'pickedUp', (
          select count(*) from app.order_lines
          where id in (
            select overlay(
              overlay(md5('capacity-line-' || value) placing '4' from 13)
              placing '8' from 17
            )::uuid
            from generate_series(1, ${criticalOrderCount}) value
          )
          and status = 'picked_up'
        )
      )::text
    `,
    true,
  ));
  if (
    committed.members !== memberCount
    || committed.lines !== orderLineCount
    || committed.sessions !== staffSessionCount
    || committed.pickedUp !== criticalOrderCount
  ) {
    throw new Error("Het capaciteitseindbewijs is niet sluitend.");
  }

  if (sensitiveValues.some((value) => appLogs.includes(value))) {
    throw new Error("LOG_PRIVACY_RUNTIME_SENTINEL_FOUND");
  }

  const pageSummary = summary(pageLatencies);
  const exchangeSummary = summary(exchangeLatencies);
  const commitSummary = summary(commitMeasurements);
  process.stdout.write(
    [
      `Capaciteitstest geslaagd: ${memberCount} leden`,
      `${orderLineCount} orderregels`,
      `${staffSessionCount} gelijktijdige staffsessies`,
      `staff p95 ${pageSummary.p95} ms`,
      `QR p95 ${exchangeSummary.p95} ms`,
      `uitgifte p95 ${commitSummary.p95} ms`,
    ].join("; ") + ".\n",
  );
} finally {
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
  resetLocalDatabase();
}
