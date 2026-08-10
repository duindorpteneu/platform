import { lstatSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const configured = process.env.SUPABASE_CLI_BINARY_OVERRIDE?.trim();
if (configured && (
  !path.isAbsolute(configured)
  || !lstatSync(configured, { throwIfNoEntry: false })?.isFile()
)) {
  throw new Error("De geverifieerde Supabase CLI-override is ongeldig.");
}

const executable = configured || "supabase";
const args = process.argv.slice(2);
if (args.length === 0) {
  throw new Error("Een Supabase CLI-opdracht is verplicht.");
}

const result = spawnSync(executable, args, {
  cwd: process.cwd(),
  env: process.env,
  stdio: "inherit",
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
