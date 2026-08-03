import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { chromium } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { settingsWorkspaceSchema } from "../../src/lib/settings-audit-contract.ts";

const STAGING_ORIGIN = "https://staging-duindorp.dgwebservices.nl";
const STAGING_REF = "dxbdjtbyghsovlrdcwcr";
const POSTGRES_IMAGE = "public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453";
const roles = ["beheerder", "kledingcommissie", "uitgifte"];
const ACCEPTANCE_EMAIL = /^staging-acceptance-.+@example\.invalid$/;

function timedFetch(input, init = {}) {
  const timeout = AbortSignal.timeout(15_000);
  const signal = init.signal ? AbortSignal.any([init.signal, timeout]) : timeout;
  return fetch(input, { ...init, signal });
}

function supabaseOptions() {
  return {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: timedFetch },
  };
}

async function withDeadline(promise, milliseconds, code) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(code)), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function envRequired(environment, name) {
  const value = environment[name]?.trim() ?? "";
  if (!value || /[\r\n\0]/.test(value)) throw new Error(`MISSING_${name}`);
  return value;
}

export function targetFromEnvironment(environment = process.env) {
  const baseUrl = envRequired(environment, "STAGING_BASE_URL");
  const projectRef = envRequired(environment, "SUPABASE_PROJECT_REF");
  const releaseSha = envRequired(environment, "RELEASE_SHA");
  const confirmation = envRequired(environment, "CONFIRMATION");
  if (baseUrl !== STAGING_ORIGIN || projectRef !== STAGING_REF) throw new Error("STAGING_TARGET_INVALID");
  if (!/^[a-f0-9]{40}$/.test(releaseSha)) throw new Error("RELEASE_SHA_INVALID");
  if (confirmation !== "STAGING-CORE") throw new Error("CONFIRMATION_INVALID");
  return { baseUrl, projectRef, releaseSha };
}

export function databaseTargetFromEnvironment(environment = process.env) {
  const databaseUrl = envRequired(environment, "SUPABASE_DB_URL");
  let parsed;
  try {
    parsed = new URL(databaseUrl);
  } catch {
    throw new Error("STAGING_DATABASE_TARGET_INVALID");
  }
  if (!["postgres:", "postgresql:"].includes(parsed.protocol)) throw new Error("STAGING_DATABASE_TARGET_INVALID");
  if (!`${parsed.hostname}|${decodeURIComponent(parsed.username)}`.includes(STAGING_REF)) {
    throw new Error("STAGING_DATABASE_TARGET_INVALID");
  }
  return databaseUrl;
}

async function mutateStaffProfile(action, databaseUrl, fixture) {
  const statements = {
    insert: "insert into app.staff_profiles(auth_user_id, display_name, role, active) values (:'user_id'::uuid, :'display_name', :'role'::app.staff_role, true) on conflict (auth_user_id) do update set display_name = excluded.display_name, role = excluded.role, active = true;",
    delete: "delete from app.staff_profiles where auth_user_id = :'user_id'::uuid;",
  };
  const statement = statements[action];
  if (!statement) throw new Error("STAFF_PROFILE_ACTION_INVALID");
  const environment = {
    ...process.env,
    TARGET_DB_URL: databaseUrl,
    PROFILE_USER_ID: fixture.userId,
    PROFILE_DISPLAY_NAME: fixture.displayName,
    PROFILE_ROLE: fixture.role,
  };
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const result = spawnSync("docker", [
      "run", "--rm", "--interactive", "--read-only", "--cap-drop=ALL", "--security-opt", "no-new-privileges:true", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m",
      "--env", "TARGET_DB_URL", "--env", "PROFILE_USER_ID", "--env", "PROFILE_DISPLAY_NAME", "--env", "PROFILE_ROLE",
      "--entrypoint", "sh", POSTGRES_IMAGE, "-ceu",
      "psql \"$TARGET_DB_URL\" --no-psqlrc --set=ON_ERROR_STOP=1 --set=user_id=\"$PROFILE_USER_ID\" --set=display_name=\"$PROFILE_DISPLAY_NAME\" --set=role=\"$PROFILE_ROLE\"",
    ], { env: environment, input: statement, encoding: "utf8", stdio: ["pipe", "ignore", "ignore"], timeout: 45_000 });
    if (result.status === 0) return;
    if (attempt < 2) await wait(1_000);
  }
  throw new Error(action === "insert" ? "STAFF_PROFILE_CREATE_FAILED" : "STAFF_PROFILE_CLEANUP_FAILED");
}

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.replace(/=+$/, "").toUpperCase()) {
    const position = alphabet.indexOf(character);
    if (position < 0) throw new Error("TOTP_SECRET_INVALID");
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

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForFixtureAuth(supabaseUrl, anonKey, email, password) {
  const client = createClient(supabaseUrl, anonKey, supabaseOptions());
  for (let attempt = 1; attempt <= 6; attempt += 1) {
    const result = await withDeadline(
      client.auth.signInWithPassword({ email, password }),
      20_000,
      "STAFF_FIXTURE_AUTH_TIMEOUT",
    );
    if (!result.error && result.data.session) {
      await withDeadline(client.auth.signOut({ scope: "local" }), 5_000, "STAFF_FIXTURE_SIGNOUT_TIMEOUT");
      return;
    }
    if (attempt < 6) await wait(attempt * 1_000);
  }
  throw new Error("STAFF_FIXTURE_AUTH_NOT_READY");
}

async function verifyStaffSessionRpc(admin, userId) {
  const issued = await withDeadline(
    admin.schema("app").rpc("create_staff_app_session_for_user", { p_auth_user_id: userId }),
    20_000,
    "STAFF_SESSION_RPC_TIMEOUT",
  );
  if (issued.error) {
    const code = typeof issued.error.code === "string" && /^[A-Z0-9_]{2,32}$/.test(issued.error.code)
      ? issued.error.code
      : "UNKNOWN";
    throw new Error(`STAFF_SESSION_RPC_${code}`);
  }
  const token = issued.data?.sessionToken;
  if (typeof token !== "string" || !/^[a-f0-9]{64}$/.test(token)) throw new Error("STAFF_SESSION_RPC_RESPONSE_INVALID");
  const revoked = await withDeadline(
    admin.schema("app").rpc("revoke_staff_app_session", { p_session_token: token }),
    20_000,
    "STAFF_SESSION_RPC_REVOKE_TIMEOUT",
  );
  if (revoked.error || typeof revoked.data !== "number" || revoked.data < 1) {
    throw new Error("STAFF_SESSION_RPC_REVOKE_FAILED");
  }
  process.stdout.write("Service-role sessiecontract en intrekking geslaagd.\n");
}

async function removeAcceptanceUser(admin, databaseUrl, userId) {
  await mutateStaffProfile("delete", databaseUrl, { userId, displayName: "cleanup", role: "uitgifte" });
  const deleted = await withDeadline(admin.auth.admin.deleteUser(userId), 20_000, "STAFF_FIXTURE_DELETE_TIMEOUT");
  if (deleted.error) throw new Error("STAFF_FIXTURE_CLEANUP_FAILED");
}

async function cleanupStaleFixtures(admin, databaseUrl) {
  const staleUserIds = [];
  for (let page = 1; page <= 10; page += 1) {
    const listed = await withDeadline(
      admin.auth.admin.listUsers({ page, perPage: 1000 }),
      20_000,
      "STAFF_FIXTURE_LIST_TIMEOUT",
    );
    if (listed.error) throw new Error("STAFF_FIXTURE_LIST_FAILED");
    for (const user of listed.data.users) {
      if (!ACCEPTANCE_EMAIL.test(user.email ?? "")) continue;
      staleUserIds.push(user.id);
    }
    if (listed.data.users.length < 1000) break;
  }
  for (const userId of staleUserIds) await removeAcceptanceUser(admin, databaseUrl, userId);
  process.stdout.write(`Staging-acceptatie: ${staleUserIds.length} achtergebleven fixture(s) opgeruimd.\n`);
}

async function verifyHealth(target) {
  const response = await fetch(`${target.baseUrl}/api/health`, { redirect: "error", signal: AbortSignal.timeout(10_000) });
  const body = await response.json();
  if (!response.ok || body.status !== "ok" || body.environment !== "staging" || body.revision !== target.releaseSha) {
    throw new Error("STAGING_RELEASE_MISMATCH");
  }
}

async function loginWithMfa(page, baseUrl, projectRef, email, password) {
  let authStatus = 0;
  page.on("response", (response) => {
    const url = new URL(response.url());
    if (url.hostname === `${projectRef}.supabase.co` && url.pathname.includes("/auth/v1/factors/") && url.pathname.endsWith("/verify")) {
      process.stdout.write(`MFA-providerantwoord ontvangen (${response.status()}).\n`);
    }
    if (url.origin === baseUrl && url.pathname === "/api/staff-auth/session") {
      process.stdout.write(`App-sessieantwoord ontvangen (${response.status()}).\n`);
    }
  });
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (request.method() === "POST" && url.origin === baseUrl && url.pathname === "/api/staff-auth/session") {
      process.stdout.write("App-sessieverzoek verzonden.\n");
    }
  });
  page.on("requestfailed", (request) => {
    const url = new URL(request.url());
    if (request.method() === "POST" && url.origin === baseUrl && url.pathname === "/api/staff-auth/session") {
      process.stdout.write("App-sessieverzoek door de browser afgebroken.\n");
    }
  });
  try {
    await page.goto(`${baseUrl}/staff/login`);
    const runtime = await page.evaluate(() => ({
      supabaseUrl: globalThis.__DUINDORP_RUNTIME_CONFIG__?.supabaseUrl ?? "",
      keyLength: globalThis.__DUINDORP_RUNTIME_CONFIG__?.supabasePublishableKey?.length ?? 0,
    }));
    if (runtime.supabaseUrl !== `https://${projectRef}.supabase.co` || runtime.keyLength < 20) {
      throw new Error("STAFF_RUNTIME_CONFIG_INVALID");
    }
    await page.getByLabel("E-mailadres").fill(email);
    await page.getByLabel("Wachtwoord").fill(password);
    const authResponse = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return response.request().method() === "POST"
        && url.hostname === `${projectRef}.supabase.co`
        && url.pathname === "/auth/v1/token";
    }, { timeout: 30_000 });
    await page.getByRole("button", { name: "Inloggen" }).click();
    authStatus = (await authResponse).status();
    if (authStatus === 400) throw new Error("STAFF_PASSWORD_REJECTED");
    if (authStatus === 429) throw new Error("STAFF_AUTH_RATE_LIMITED");
    if (authStatus !== 200) throw new Error("STAFF_AUTH_PROVIDER_REJECTED");
    await page.waitForURL(`${baseUrl}/staff/mfa`, { timeout: 15_000 });
  } catch (error) {
    if (error instanceof Error && [
      "STAFF_RUNTIME_CONFIG_INVALID",
      "STAFF_PASSWORD_REJECTED",
      "STAFF_AUTH_RATE_LIMITED",
      "STAFF_AUTH_PROVIDER_REJECTED",
    ].includes(error.message)) throw error;
    const alert = await page.getByRole("alert").textContent({ timeout: 1_000 }).catch(() => "");
    if (alert?.includes("E-mailadres of wachtwoord is niet geldig")) throw new Error("STAFF_PASSWORD_REJECTED");
    if (alert?.includes("Medewerkerslogin is lokaal nog niet geconfigureerd")) throw new Error("STAFF_RUNTIME_CONFIG_MISSING");
    if (authStatus === 200) throw new Error("STAFF_LOGIN_NAVIGATION_FAILED");
    if (authStatus > 0) throw new Error("STAFF_AUTH_PROVIDER_REJECTED");
    if (error instanceof Error && error.name === "TimeoutError") throw new Error("STAFF_AUTH_NO_RESPONSE");
    throw new Error("STAFF_LOGIN_REDIRECT_TIMEOUT");
  }
  let secret;
  try {
    secret = (await page.locator("p.font-mono").textContent({ timeout: 15_000 }))?.trim();
  } catch {
    throw new Error("MFA_ENROLLMENT_FAILED");
  }
  if (!secret) throw new Error("MFA_ENROLLMENT_SECRET_MISSING");
  process.stdout.write("MFA-formulier en enrollmentsleutel gereed.\n");
  let syncResponse;
  try {
    const pendingSync = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return response.request().method() === "POST"
        && url.origin === baseUrl
        && url.pathname === "/api/staff-auth/session";
    }, { timeout: 30_000 });
    await page.getByLabel("Zescijferige verificatiecode").fill(currentTotp(secret));
    await withDeadline(
      page.getByRole("button", { name: "Beveiligde sessie starten" }).evaluate((element) => element.click()),
      5_000,
      "MFA_CLICK_FAILED",
    );
    process.stdout.write("MFA-submit direct naar de pagina verstuurd.\n");
    syncResponse = await withDeadline(pendingSync, 35_000, "MFA_SESSION_RESPONSE_TIMEOUT");
  } catch (error) {
    if (error instanceof Error && ["MFA_CLICK_FAILED", "MFA_SESSION_RESPONSE_TIMEOUT"].includes(error.message)) throw error;
    throw new Error("MFA_SUBMIT_FAILED");
  }
  if (!syncResponse.ok()) {
    const safeError = await syncResponse.headerValue("x-duindorp-auth-error");
    const errors = {
      INVALID_SESSION_TOKENS: "MFA_SYNC_TOKENS_INVALID",
      STAFF_JWT_UNAVAILABLE: "MFA_SYNC_JWT_UNAVAILABLE",
      STAFF_SESSION_UNAVAILABLE: "MFA_SYNC_SESSION_UNAVAILABLE",
      STAFF_SESSION_REJECTED: "MFA_SYNC_SESSION_REJECTED",
      STAFF_AAL2_REQUIRED: "MFA_SYNC_AAL2_REQUIRED",
      STAFF_PROFILE_REQUIRED: "MFA_SYNC_PROFILE_REQUIRED",
    };
    throw new Error(errors[safeError] ?? "MFA_SYNC_REQUEST_REJECTED");
  }
  const sessionRequestPayload = syncResponse.request().postDataJSON();
  const accessToken = sessionRequestPayload?.accessToken;
  if (typeof accessToken !== "string" || accessToken.split(".").length !== 3) throw new Error("MFA_ACCESS_TOKEN_INVALID");
  return accessToken;
}

async function verifyMobileMenu(page, role) {
  await page.setViewportSize({ width: 390, height: 844 });
  const opener = page.getByRole("button", { name: "Menu openen" });
  const dialog = page.getByRole("dialog", { name: "Mobiele navigatie" });
  try {
    await opener.waitFor({ state: "visible", timeout: 15_000 });
    await opener.click();
    await dialog.waitFor({ state: "visible", timeout: 15_000 });
  } catch {
    throw new Error("MOBILE_MENU_OPEN_FAILED");
  }
  const issuanceLink = dialog.getByRole("link", {
    name: "Uitgifte",
    exact: true,
  });
  if (role === "kledingcommissie") {
    if (await issuanceLink.count()) {
      throw new Error("COMMITTEE_ISSUANCE_EXPOSED");
    }
  } else {
    await issuanceLink.waitFor();
  }
  if (role === "uitgifte") {
    if (await dialog.getByRole("link", { name: "Dashboard", exact: true }).count()) throw new Error("ISSUANCE_MENU_OVEREXPOSED");
  } else {
    await dialog.getByRole("link", { name: "Dashboard", exact: true }).waitFor();
  }
  await page.keyboard.press("Escape");
  await dialog.waitFor({ state: "hidden", timeout: 15_000 });
  if (!(await opener.evaluate((element) => element === document.activeElement))) throw new Error("MENU_FOCUS_NOT_RESTORED");
}

async function verifyAdminSettings(page, baseUrl) {
  const settingsUrl = `${baseUrl}/backoffice/instellingen`;
  let responseStatus = 0;
  const recordResponse = (response) => {
    if (response.request().resourceType() === "document" && response.url() === settingsUrl) {
      responseStatus = response.status();
      process.stdout.write(`Beheerder-instellingen antwoord ontvangen (${responseStatus}).\n`);
    }
  };
  page.on("response", recordResponse);
  try {
    await page.evaluate((url) => window.location.assign(url), settingsUrl);
    await page.waitForURL(settingsUrl, { timeout: 15_000 });
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      if (page.url().startsWith(`${baseUrl}/staff/login`)) throw new Error("ADMIN_SETTINGS_SESSION_LOST");
      if (await page.getByRole("heading", { name: "Instellingen", exact: true }).isVisible().catch(() => false)) {
        process.stdout.write("Beheerder-instellingen zichtbaar.\n");
        return;
      }
      const body = await page.locator("body").innerText({ timeout: 1_000 }).catch(() => "");
      if (body.includes("Instellingen tijdelijk niet beschikbaar") || body.includes("Instellingen niet beschikbaar")) {
        throw new Error("ADMIN_SETTINGS_WORKSPACE_UNAVAILABLE");
      }
      await wait(250);
    }
    if (responseStatus >= 400) throw new Error("ADMIN_SETTINGS_HTTP_REJECTED");
    throw new Error("ADMIN_SETTINGS_RENDER_TIMEOUT");
  } catch (error) {
    if (error instanceof Error && /^ADMIN_SETTINGS_[A-Z_]+$/.test(error.message)) throw error;
    throw new Error("ADMIN_SETTINGS_NAVIGATION_FAILED");
  } finally {
    page.off("response", recordResponse);
  }
}

async function verifyAdminSettingsRpc(target, anonKey, accessToken) {
  const response = await timedFetch(`https://${target.projectRef}.supabase.co/rest/v1/rpc/get_settings_workspace_v2`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Accept-Profile": "app",
      apikey: anonKey,
      Authorization: `Bearer ${accessToken}`,
      "Content-Profile": "app",
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const providerCode = typeof payload?.code === "string" && /^[A-Z0-9_]{2,32}$/.test(payload.code)
      ? payload.code
      : "UNKNOWN";
    process.stdout.write(`Direct instellingen-RPC afgewezen (${response.status}, ${providerCode}).\n`);
    throw new Error(`ADMIN_SETTINGS_RPC_${providerCode}`);
  }
  const parsed = settingsWorkspaceSchema.safeParse(payload);
  if (!parsed.success) {
    const paths = [...new Set(parsed.error.issues.map((issue) => issue.path.join(".") || "root"))]
      .slice(0, 8)
      .join(",");
    process.stdout.write(`Direct instellingen-RPC contract ongeldig (${paths}).\n`);
    throw new Error("ADMIN_SETTINGS_RPC_RESPONSE_INVALID");
  }
  process.stdout.write("Direct instellingen-RPC en responsecontract geslaagd (200).\n");
  return parsed.data;
}

async function verifyRole(page, target, role, anonKey, accessToken) {
  if (role === "uitgifte") {
    await page.goto(`${target.baseUrl}/backoffice`);
    await page.waitForURL(`${target.baseUrl}/uitgifte`, { timeout: 15_000 });
    await page.getByRole("heading", { name: "Uitgifte" }).waitFor();
  } else {
    try {
      await page.waitForURL(`${target.baseUrl}/backoffice`, { timeout: 15_000 });
    } catch {
      const alert = await page.getByRole("alert").textContent({ timeout: 1_000 }).catch(() => "");
      if (alert?.includes("verificatiecode is niet geldig of verlopen")) throw new Error("MFA_CODE_REJECTED");
      if (alert?.includes("beveiligde sessie kon niet worden bevestigd")) throw new Error("MFA_AAL2_NOT_CONFIRMED");
      if (alert?.includes("geen actief medewerkersprofiel")) throw new Error("MFA_STAFF_SESSION_REJECTED");
      throw new Error("MFA_LANDING_FAILED");
    }
    const sessionStatus = await page.evaluate(async () => (await fetch("/api/staff-auth/session", { headers: { accept: "application/json" } })).status);
    if (sessionStatus !== 200) throw new Error("STAFF_APP_SESSION_NOT_AVAILABLE");
    if (role === "beheerder") {
      await verifyAdminSettingsRpc(target, anonKey, accessToken);
      await verifyAdminSettings(page, target.baseUrl);
    }
    if (role === "kledingcommissie" && await page.getByRole("link", { name: "Instellingen", exact: true }).count()) {
      throw new Error("COMMITTEE_SETTINGS_EXPOSED");
    }
    if (role === "kledingcommissie") {
      await page.goto(`${target.baseUrl}/uitgifte`);
      await page.waitForURL(`${target.baseUrl}/backoffice`, {
        timeout: 15_000,
      });
    }
  }
  await verifyMobileMenu(page, role);
}

async function main() {
  const target = targetFromEnvironment();
  const supabaseUrl = envRequired(process.env, "NEXT_PUBLIC_SUPABASE_URL");
  const anonKey = envRequired(process.env, "NEXT_PUBLIC_SUPABASE_ANON_KEY");
  const serviceKey = envRequired(process.env, "SUPABASE_SERVICE_ROLE_KEY");
  const databaseUrl = databaseTargetFromEnvironment();
  if (supabaseUrl !== `https://${target.projectRef}.supabase.co`) throw new Error("SUPABASE_URL_INVALID");
  if (anonKey.length < 20) throw new Error("SUPABASE_ANON_KEY_INVALID");
  if (process.env.CLEANUP_ONLY !== "1") await verifyHealth(target);

  const admin = createClient(supabaseUrl, serviceKey, supabaseOptions());
  await cleanupStaleFixtures(admin, databaseUrl);
  if (process.env.CLEANUP_ONLY === "1") return;
  const browser = await withDeadline(chromium.launch({ headless: true }), 20_000, "BROWSER_LAUNCH_TIMEOUT");
  const createdUsers = [];
  try {
    for (const role of roles) {
      const marker = `${process.env.GITHUB_RUN_ID ?? Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
      const email = `staging-acceptance-${marker}-${role}@example.invalid`;
      const password = `${crypto.randomBytes(24).toString("base64url")}!Aa1`;
      process.stdout.write(`${role}: tijdelijke authfixture aanmaken…\n`);
      const created = await withDeadline(
        admin.auth.admin.createUser({ email, password, email_confirm: true }),
        20_000,
        "STAFF_FIXTURE_CREATE_TIMEOUT",
      );
      if (created.error || !created.data.user) throw new Error("STAFF_FIXTURE_CREATE_FAILED");
      createdUsers.push(created.data.user.id);
      await mutateStaffProfile("insert", databaseUrl, {
        userId: created.data.user.id,
        displayName: `Staging ${role}`,
        role,
      });
      await verifyStaffSessionRpc(admin, created.data.user.id);
      await waitForFixtureAuth(supabaseUrl, anonKey, email, password);
      process.stdout.write(`${role}: tijdelijke fixture gereed.\n`);

      const context = await withDeadline(
        browser.newContext({ viewport: { width: 390, height: 844 } }),
        10_000,
        "BROWSER_CONTEXT_CREATE_TIMEOUT",
      );
      try {
        const page = await withDeadline(context.newPage(), 10_000, "BROWSER_PAGE_CREATE_TIMEOUT");
        page.setDefaultTimeout(15_000);
        page.setDefaultNavigationTimeout(15_000);
        const accessToken = await loginWithMfa(page, target.baseUrl, target.projectRef, email, password);
        process.stdout.write(`${role}: MFA-code ingediend.\n`);
        await verifyRole(page, target, role, anonKey, accessToken);
      } finally {
        await withDeadline(context.close(), 10_000, "BROWSER_CONTEXT_CLOSE_TIMEOUT").catch(() => undefined);
      }
      process.stdout.write(`${role}: MFA, rolgrens en mobiel menu geslaagd.\n`);
    }
  } finally {
    await withDeadline(browser.close(), 10_000, "BROWSER_CLOSE_TIMEOUT").catch(() => undefined);
    let cleanupFailed = false;
    for (const userId of createdUsers.reverse()) {
      try {
        await removeAcceptanceUser(admin, databaseUrl, userId);
      } catch {
        cleanupFailed = true;
      }
    }
    if (cleanupFailed) throw new Error("STAFF_FIXTURE_CLEANUP_FAILED");
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      const code = error instanceof Error && /^[A-Z0-9_]+$/.test(error.message) ? error.message : "STAGING_CORE_ACCEPTANCE_FAILED";
      process.stderr.write(`${code}\n`);
      process.exit(1);
    });
}
