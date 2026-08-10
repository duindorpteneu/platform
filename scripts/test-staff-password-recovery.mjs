import assert from "node:assert/strict";
import crypto from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import net from "node:net";
import { chromium } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

const host = "localhost";
const port = 3100;
const baseUrl = `http://${host}:${port}`;
const mailpitUrl = "http://127.0.0.1:54359";
const email = "staff-recovery-browser@example.invalid";
const oldPassword = "Duindorp-Recovery-Old-2026!";
const newPassword = "Duindorp-Recovery-New-2026!";
const pepper = "staff-recovery-browser-parent-pepper-2026";

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

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.replace(/=+$/, "").toUpperCase()) {
    const position = alphabet.indexOf(character);
    if (position < 0) throw new Error("STAFF_RECOVERY_TOTP_SECRET_INVALID");
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

function portIsAvailable() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => server.close(() => resolve(true)));
    server.listen(port, host);
  });
}

async function waitForApp(processHandle) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (processHandle.exitCode !== null) throw new Error("STAFF_RECOVERY_APP_EXITED");
    try {
      const response = await fetch(`${baseUrl}/staff/login`, { redirect: "manual" });
      if (response.status === 200) return;
    } catch {
      // De server start nog op.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("STAFF_RECOVERY_APP_TIMEOUT");
}

async function listMailpitMessages() {
  const response = await fetch(`${mailpitUrl}/api/v1/messages`);
  if (!response.ok) throw new Error("STAFF_RECOVERY_MAILPIT_UNAVAILABLE");
  const payload = await response.json();
  return Array.isArray(payload.messages) ? payload.messages : [];
}

function findRecoveryUrl(value) {
  if (typeof value === "string") {
    const matches = value.replaceAll("&amp;", "&").match(/https?:\/\/[^\s"'<>]+/g) ?? [];
    return matches.find((candidate) => candidate.includes("/auth/v1/verify") && candidate.includes("type=recovery")) ?? null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const match = findRecoveryUrl(item);
      if (match) return match;
    }
  }
  if (value && typeof value === "object") {
    for (const item of Object.values(value)) {
      const match = findRecoveryUrl(item);
      if (match) return match;
    }
  }
  return null;
}

async function waitForRecoveryLink(previousIds) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const messages = await listMailpitMessages();
    const message = messages.find((candidate) => !previousIds.has(candidate.ID) && JSON.stringify(candidate).includes(email));
    if (message?.ID) {
      const response = await fetch(`${mailpitUrl}/api/v1/message/${encodeURIComponent(message.ID)}`);
      if (!response.ok) throw new Error("STAFF_RECOVERY_MAILPIT_MESSAGE_UNAVAILABLE");
      const link = findRecoveryUrl(await response.json());
      if (link) return link;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("STAFF_RECOVERY_EMAIL_MISSING");
}

function stopProcess(processHandle) {
  if (!processHandle || processHandle.exitCode !== null) return;
  try { process.kill(-processHandle.pid, "SIGTERM"); } catch { /* proces is al gestopt */ }
}

const local = localSupabaseEnv();
for (const name of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY"]) {
  if (!local[name]) throw new Error(`STAFF_RECOVERY_MISSING_${name}`);
}
if (!(await portIsAvailable())) throw new Error("STAFF_RECOVERY_PORT_OCCUPIED");

const admin = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});
runSql(local.DB_URL, "delete from private.rate_limit_events where scope = 'staff_recovery';");
const existing = await admin.auth.admin.listUsers();
if (existing.error) throw new Error("STAFF_RECOVERY_AUTH_LIST_FAILED");
for (const user of existing.data.users.filter((candidate) => candidate.email === email)) {
  runSql(local.DB_URL, `delete from app.audit_logs where actor_user_id = '${user.id}'::uuid; delete from private.staff_sessions where auth_user_id = '${user.id}'::uuid; delete from app.staff_profiles where auth_user_id = '${user.id}'::uuid;`);
  await admin.auth.admin.deleteUser(user.id);
}

let userId;
let browser;
let appProcess;
try {
  const created = await admin.auth.admin.createUser({ email, password: oldPassword, email_confirm: true });
  if (created.error || !created.data.user) throw new Error("STAFF_RECOVERY_AUTH_CREATE_FAILED");
  userId = created.data.user.id;
  runSql(local.DB_URL, `insert into app.staff_profiles(auth_user_id, display_name, role, active) values ('${userId}'::uuid, 'Recovery browsertest', 'beheerder', true);`);

  const enrolledClient = createClient(local.API_URL, local.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const signedIn = await enrolledClient.auth.signInWithPassword({ email, password: oldPassword });
  if (signedIn.error) throw new Error("STAFF_RECOVERY_OLD_LOGIN_FAILED");
  const enrolled = await enrolledClient.auth.mfa.enroll({ factorType: "totp", friendlyName: "Recovery browsertest", issuer: "Duindorp SV" });
  if (enrolled.error || !enrolled.data) throw new Error("STAFF_RECOVERY_MFA_ENROLL_FAILED");
  const verified = await enrolledClient.auth.mfa.challengeAndVerify({ factorId: enrolled.data.id, code: currentTotp(enrolled.data.totp.secret) });
  if (verified.error) throw new Error("STAFF_RECOVERY_MFA_VERIFY_FAILED");

  const appSession = await admin.schema("app").rpc("create_staff_app_session_for_user", { p_auth_user_id: userId });
  const oldAppSessionToken = appSession.data?.sessionToken;
  if (appSession.error || !/^[0-9a-f]{64}$/.test(oldAppSessionToken ?? "")) throw new Error("STAFF_RECOVERY_APP_SESSION_CREATE_FAILED");

  appProcess = spawn("pnpm", ["start", "--hostname", host, "--port", String(port)], {
    detached: true,
    stdio: "ignore",
    env: {
      ...process.env,
      APP_BASE_URL: baseUrl,
      NEXT_PUBLIC_SUPABASE_URL: local.API_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: local.ANON_KEY,
      SUPABASE_SECRET_KEY: local.SERVICE_ROLE_KEY,
      PARENT_TOKEN_PEPPER: pepper,
      EMAIL_ENABLED: "false",
      MOLLIE_ENABLED: "false",
    },
  });
  await waitForApp(appProcess);

  const previousIds = new Set((await listMailpitMessages()).map((message) => message.ID));
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto(`${baseUrl}/staff/login`);
  await page.getByRole("link", { name: "Wachtwoord vergeten?" }).click();
  await page.waitForURL(`${baseUrl}/staff/wachtwoord-vergeten`);
  await page.getByLabel("E-mailadres").fill(email);
  await page.getByRole("button", { name: "Herstellink aanvragen" }).click();
  await page.getByText("Als dit e-mailadres bij een medewerkersaccount hoort", { exact: false }).waitFor();

  const recoveryLink = await waitForRecoveryLink(previousIds);
  await page.goto(recoveryLink);
  await page.waitForURL((url) => url.origin === baseUrl && url.pathname === "/staff/reset-password");
  await page.getByRole("heading", { name: "Kies een nieuw wachtwoord" }).waitFor();
  await page.getByLabel("Zescijferige verificatiecode").fill(currentTotp(enrolled.data.totp.secret));
  await page.getByLabel("Nieuw wachtwoord").fill(newPassword);
  await page.getByLabel("Herhaal wachtwoord").fill(newPassword);
  const passwordUpdateResponse = page.waitForResponse(
    (response) => new URL(response.url()).pathname === "/auth/v1/user" && response.request().method() === "PUT",
    { timeout: 10_000 },
  );
  const completionResponse = page.waitForResponse(
    (response) => new URL(response.url()).pathname === "/api/staff-auth/password-changed",
    { timeout: 10_000 },
  ).catch(() => null);
  await page.getByRole("button", { name: "Wachtwoord opslaan" }).click();
  const passwordUpdate = await passwordUpdateResponse;
  if (passwordUpdate.status() !== 200) {
    const providerError = await passwordUpdate.json().catch(() => null);
    const safeCode = typeof providerError?.code === "string" && /^[a-z0-9_]+$/.test(providerError.code)
      ? providerError.code.toUpperCase()
      : String(passwordUpdate.status());
    throw new Error(`STAFF_RECOVERY_PASSWORD_UPDATE_${safeCode}`);
  }
  const completion = await completionResponse;
  if (!completion) {
    const safeAlert = await page.getByRole("alert").textContent().catch(() => "STAFF_RECOVERY_FORM_FAILED");
    throw new Error(safeAlert || "STAFF_RECOVERY_FORM_FAILED");
  }
  assert.equal(completion.status(), 204, "STAFF_RECOVERY_SESSION_REVOCATION_FAILED");
  await page.waitForURL(`${baseUrl}/staff/login?wachtwoord=gewijzigd`);
  await page.getByText("Je wachtwoord is gewijzigd en bestaande sessies zijn beëindigd.", { exact: false }).waitFor();

  const oldLogin = createClient(local.API_URL, local.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  assert.ok((await oldLogin.auth.signInWithPassword({ email, password: oldPassword })).error, "STAFF_RECOVERY_OLD_PASSWORD_STILL_VALID");
  const newLogin = createClient(local.API_URL, local.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  assert.equal((await newLogin.auth.signInWithPassword({ email, password: newPassword })).error, null, "STAFF_RECOVERY_NEW_PASSWORD_INVALID");
  const factors = await newLogin.auth.mfa.listFactors();
  assert.equal(factors.error, null);
  assert.equal(factors.data?.totp.length, 1, "STAFF_RECOVERY_TOTP_FACTOR_DRIFT");
  const oldContext = await admin.schema("app").rpc("get_staff_app_session", { p_session_token: oldAppSessionToken });
  assert.equal(oldContext.error, null);
  assert.equal(oldContext.data, null, "STAFF_RECOVERY_OLD_APP_SESSION_STILL_VALID");

  await page.getByLabel("E-mailadres").fill(email);
  await page.getByLabel("Wachtwoord").fill(newPassword);
  await page.getByRole("button", { name: "Inloggen" }).click();
  await page.waitForURL(`${baseUrl}/staff/mfa`);
  await page.getByRole("heading", { name: "MFA bevestigen" }).waitFor();
  await page.getByText("Tweede stap vereist", { exact: true }).waitFor();

  const fallbackMessageIds = new Set((await listMailpitMessages()).map((message) => message.ID));
  const dashboardStyleRecovery = await admin.auth.resetPasswordForEmail(email);
  if (dashboardStyleRecovery.error) throw new Error("STAFF_RECOVERY_SITE_URL_REQUEST_FAILED");
  await page.goto(await waitForRecoveryLink(fallbackMessageIds));
  await page.waitForURL((url) => url.origin === baseUrl && url.pathname === "/staff/reset-password");
  await page.getByRole("heading", { name: "Kies een nieuw wachtwoord" }).waitFor();
  process.stdout.write("Medewerker-wachtwoordherstel geslaagd: neutraal verzoek, dashboardfallback, sessie-intrekking en MFA-behoud bewezen.\n");
} finally {
  if (browser) await browser.close().catch(() => undefined);
  stopProcess(appProcess);
  if (userId) {
    try {
      runSql(local.DB_URL, `delete from app.audit_logs where actor_user_id = '${userId}'::uuid; delete from private.staff_sessions where auth_user_id = '${userId}'::uuid; delete from app.staff_profiles where auth_user_id = '${userId}'::uuid;`);
    } catch { /* Auth-opruiming gaat door. */ }
    await admin.auth.admin.deleteUser(userId);
  }
}
