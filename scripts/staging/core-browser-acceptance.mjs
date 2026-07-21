import crypto from "node:crypto";
import { pathToFileURL } from "node:url";
import { chromium } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

const STAGING_ORIGIN = "https://staging-duindorp.dgwebservices.nl";
const STAGING_REF = "dxbdjtbyghsovlrdcwcr";
const roles = ["beheerder", "kledingcommissie", "uitgifte"];

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

async function verifyHealth(target) {
  const response = await fetch(`${target.baseUrl}/api/health`, { redirect: "error", signal: AbortSignal.timeout(10_000) });
  const body = await response.json();
  if (!response.ok || body.status !== "ok" || body.environment !== "staging" || body.revision !== target.releaseSha) {
    throw new Error("STAGING_RELEASE_MISMATCH");
  }
}

async function loginWithMfa(page, baseUrl, email, password) {
  await page.goto(`${baseUrl}/staff/login`);
  await page.getByLabel("E-mailadres").fill(email);
  await page.getByLabel("Wachtwoord").fill(password);
  await page.getByRole("button", { name: "Inloggen" }).click();
  await page.waitForURL(`${baseUrl}/staff/mfa`);
  const secret = (await page.locator("p.font-mono").textContent())?.trim();
  if (!secret) throw new Error("MFA_ENROLLMENT_SECRET_MISSING");
  await page.getByLabel("Zescijferige verificatiecode").fill(currentTotp(secret));
  await page.getByRole("button", { name: "Beveiligde sessie starten" }).click();
}

async function verifyMobileMenu(page, role) {
  await page.setViewportSize({ width: 390, height: 844 });
  const opener = page.getByRole("button", { name: "Menu openen" });
  await opener.waitFor({ state: "visible" });
  await opener.click();
  const dialog = page.getByRole("dialog", { name: "Mobiele navigatie" });
  await dialog.waitFor({ state: "visible" });
  await dialog.getByRole("link", { name: "Uitgifte", exact: true }).waitFor();
  if (role === "uitgifte") {
    if (await dialog.getByRole("link", { name: "Dashboard", exact: true }).count()) throw new Error("ISSUANCE_MENU_OVEREXPOSED");
  } else {
    await dialog.getByRole("link", { name: "Dashboard", exact: true }).waitFor();
  }
  await page.keyboard.press("Escape");
  await dialog.waitFor({ state: "hidden" });
  if (!(await opener.evaluate((element) => element === document.activeElement))) throw new Error("MENU_FOCUS_NOT_RESTORED");
}

async function verifyRole(page, target, role) {
  if (role === "uitgifte") {
    await page.goto(`${target.baseUrl}/backoffice`);
    await page.waitForURL(`${target.baseUrl}/uitgifte`);
    await page.getByRole("heading", { name: "Uitgifte" }).waitFor();
  } else {
    await page.waitForURL(`${target.baseUrl}/backoffice`);
    const settingsStatus = await page.evaluate(async () => (await fetch("/api/settings", { headers: { accept: "application/json" } })).status);
    if (role === "beheerder" && settingsStatus !== 200) throw new Error("ADMIN_SETTINGS_DENIED");
    if (role === "kledingcommissie" && settingsStatus !== 403) throw new Error("COMMITTEE_SETTINGS_EXPOSED");
  }
  await verifyMobileMenu(page, role);
}

async function main() {
  const target = targetFromEnvironment();
  const supabaseUrl = envRequired(process.env, "NEXT_PUBLIC_SUPABASE_URL");
  const anonKey = envRequired(process.env, "NEXT_PUBLIC_SUPABASE_ANON_KEY");
  const serviceKey = envRequired(process.env, "SUPABASE_SERVICE_ROLE_KEY");
  if (supabaseUrl !== `https://${target.projectRef}.supabase.co`) throw new Error("SUPABASE_URL_INVALID");
  if (anonKey.length < 20) throw new Error("SUPABASE_ANON_KEY_INVALID");
  await verifyHealth(target);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const browser = await chromium.launch({ headless: true });
  const createdUsers = [];
  try {
    for (const role of roles) {
      const marker = `${process.env.GITHUB_RUN_ID ?? Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
      const email = `staging-acceptance-${marker}-${role}@example.invalid`;
      const password = `${crypto.randomBytes(24).toString("base64url")}!Aa1`;
      const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (created.error || !created.data.user) throw new Error("STAFF_FIXTURE_CREATE_FAILED");
      createdUsers.push(created.data.user.id);
      const profile = await admin.schema("app").from("staff_profiles").insert({
        auth_user_id: created.data.user.id,
        display_name: `Staging ${role}`,
        role,
        active: true,
      });
      if (profile.error) throw new Error("STAFF_PROFILE_CREATE_FAILED");

      const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
      try {
        const page = await context.newPage();
        await loginWithMfa(page, target.baseUrl, email, password);
        await verifyRole(page, target, role);
      } finally {
        await context.close();
      }
      process.stdout.write(`${role}: MFA, rolgrens en mobiel menu geslaagd.\n`);
    }
  } finally {
    await browser.close();
    for (const userId of createdUsers.reverse()) {
      await admin.schema("app").from("staff_profiles").delete().eq("auth_user_id", userId);
      await admin.auth.admin.deleteUser(userId);
    }
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    const code = error instanceof Error && /^[A-Z0-9_]+$/.test(error.message) ? error.message : "STAGING_CORE_ACCEPTANCE_FAILED";
    process.stderr.write(`${code}\n`);
    process.exit(1);
  });
}
