import { createInterface } from "node:readline";

const names = ["NEXT_PUBLIC_SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_DB_URL", "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY", "PARENT_TOKEN_PEPPER", "CRON_SECRET", "IMPORT_STAGING_ENCRYPTION_KEY", "OPERATIONS_HEARTBEAT_URL", "MOLLIE_API_KEY", "SENDGRID_API_KEY"];
const values = names.map((name) => process.env[name]).filter((value) => value && value.length >= 4).sort((a, b) => b.length - a.length);
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  let safe = line.replace(/postgres(?:ql)?:\/\/[^\s]+/gi, "[REDACTED_DATABASE_URL]");
  for (const value of values) safe = safe.split(value).join("[REDACTED]");
  process.stdout.write(`${safe}\n`);
}
