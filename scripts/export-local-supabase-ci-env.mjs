import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const githubEnv = process.env.GITHUB_ENV;
if (!githubEnv) throw new Error("GITHUB_ENV ontbreekt.");

const output = execFileSync("pnpm", ["exec", "supabase", "status", "-o", "env"], {
  encoding: "utf8",
  stdio: ["ignore", "pipe", "ignore"],
});
const local = Object.fromEntries(output.split(/\r?\n/).filter((line) => line.includes("=")).map((line) => {
  const separator = line.indexOf("=");
  return [line.slice(0, separator), line.slice(separator + 1).replace(/^["']|["']$/g, "")];
}));

const apiUrl = local.API_URL;
const publishableKey = local.PUBLISHABLE_KEY ?? local.ANON_KEY;
if (!apiUrl || !/^https?:\/\/[^\s]+$/.test(apiUrl) || !publishableKey || /[\r\n]/.test(publishableKey)) {
  throw new Error("Lokale Supabase-buildconfiguratie is ongeldig.");
}

appendFileSync(
  githubEnv,
  `NEXT_PUBLIC_SUPABASE_URL=${apiUrl}\nNEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${publishableKey}\n`,
  { encoding: "utf8", mode: 0o600 },
);
console.log("Lokale Supabase public buildconfiguratie is naar GITHUB_ENV geschreven.");
