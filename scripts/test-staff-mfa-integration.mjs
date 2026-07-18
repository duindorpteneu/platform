import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import { createClient } from "@supabase/supabase-js";

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

const local = localSupabaseEnv();
for (const name of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY"]) {
  if (!local[name]) throw new Error(`Lokale Supabase-status mist ${name}.`);
}

const admin = createClient(local.API_URL, local.SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const email = "mfa-integration@example.invalid";
const password = "Duindorp-Test-2026!Sterk";
let userId;

try {
  const existing = await admin.auth.admin.listUsers();
  const staleUser = existing.data?.users?.find((user) => user.email === email);
  if (staleUser) await admin.auth.admin.deleteUser(staleUser.id);

  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (created.error || !created.data.user) throw created.error ?? new Error("Testgebruiker kon niet worden aangemaakt.");
  userId = created.data.user.id;
  if (!/^[0-9a-f-]{36}$/.test(userId)) throw new Error("Ongeldig test-user-id ontvangen.");
  runSql(local.DB_URL, `insert into app.staff_profiles (auth_user_id, display_name, role) values ('${userId}', 'MFA integratietest', 'kledingcommissie')`);

  const firstSession = createClient(local.API_URL, local.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const signedIn = await firstSession.auth.signInWithPassword({ email, password });
  if (signedIn.error) throw signedIn.error;
  const before = await firstSession.auth.mfa.getAuthenticatorAssuranceLevel();
  const enrolled = await firstSession.auth.mfa.enroll({ factorType: "totp", friendlyName: "Integratietest", issuer: "Duindorp SV" });
  if (enrolled.error || !enrolled.data) throw enrolled.error ?? new Error("TOTP kon niet worden gekoppeld.");
  const verified = await firstSession.auth.mfa.challengeAndVerify({ factorId: enrolled.data.id, code: currentTotp(enrolled.data.totp.secret) });
  if (verified.error) throw verified.error;
  const after = await firstSession.auth.mfa.getAuthenticatorAssuranceLevel();
  const allowed = await firstSession.schema("app").rpc("get_stock_overview", { p_variant_id: null });

  const secondSession = createClient(local.API_URL, local.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const signedInAgain = await secondSession.auth.signInWithPassword({ email, password });
  if (signedInAgain.error) throw signedInAgain.error;
  const denied = await secondSession.schema("app").rpc("get_stock_overview", { p_variant_id: null });

  if (before.data?.currentLevel !== "aal1" || after.data?.currentLevel !== "aal2" || allowed.error || denied.error?.code !== "42501") {
    throw new Error("Onverwacht staff-MFA-integratieresultaat.");
  }
  process.stdout.write("Staff MFA-integratietest geslaagd: AAL2 toegestaan, AAL1 geblokkeerd.\n");
} finally {
  if (userId) {
    try { runSql(local.DB_URL, `delete from app.staff_profiles where auth_user_id = '${userId}'`); } catch { /* cleanup continues */ }
    await admin.auth.admin.deleteUser(userId);
  }
}
