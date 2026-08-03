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
const generatedSource = `${source.slice(0, startIndex)}${source.slice(endIndex)}`
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
  run(generatedPath);
  run(path.resolve("scripts/test-dynamic-import-browser.mjs"), {
    DYNAMIC_IMPORT_DISPOSABLE_DB: "1",
  });
} finally {
  await rm(generatedPath, { force: true });
  resetLocalDatabase();
}
