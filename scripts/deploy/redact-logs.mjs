import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";

const SECRET_NAMES = [
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_DB_URL",
  "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY",
  "PARENT_TOKEN_PEPPER",
  "QR_TOKEN_PEPPER",
  "QR_TOKEN_PREVIOUS_PEPPER",
  "CRON_SECRET",
  "IMPORT_STAGING_ENCRYPTION_KEY",
  "OPERATIONS_HEARTBEAT_URL",
  "MOLLIE_API_KEY",
  "SENDGRID_API_KEY",
  "SENDGRID_ADMIN_API_KEY",
  "SENDGRID_SMOKE_RECIPIENT",
  "E2E_MAILBOX_IMAP_USER",
  "E2E_MAILBOX_IMAP_PASSWORD",
  "STAGING_CLEANUP_BACKUP_PASSPHRASE",
  "PRODUCTION_BACKUP_PASSPHRASE",
];

function secretValues(values) {
  return SECRET_NAMES
    .map((name) => values[name])
    .filter((value) => value && value.length >= 4)
    .sort((a, b) => b.length - a.length);
}

export function redactLine(line, values = process.env) {
  let safe = String(line)
    .replace(
      /postgres(?:ql)?:\/\/[^\s"'<>]+/giu,
      "[REDACTED_DATABASE_URL]",
    )
    .replace(
      /(\bauthorization\s*[:=]\s*)(?:bearer|basic)\s+[^\s"',;]+/giu,
      "$1[REDACTED_AUTHORIZATION]",
    )
    .replace(
      /(\b(?:set-cookie|cookie)\s*[:=]\s*)[^\r\n]+/giu,
      "$1[REDACTED_COOKIE]",
    )
    .replace(
      /\b(?:q2|sg2)\.k[0-9]{1,4}\.[A-Za-z0-9_-]{20,}\b/gu,
      "[REDACTED_QR_MATERIAL]",
    )
    .replace(
      /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu,
      "[REDACTED_JWT]",
    )
    .replace(
      /\bSG\.[A-Za-z0-9._-]{10,}\b/gu,
      "[REDACTED_SENDGRID_KEY]",
    )
    .replace(
      /(\b(?:otp|verification[_-]?code)\b["']?\s*[:=]\s*["']?)[A-Za-z0-9_-]{4,}/giu,
      "$1[REDACTED_CODE]",
    )
    .replace(
      /(\bcode\b["']?\s*[:=]\s*["']?)[0-9]{6}\b/giu,
      "$1[REDACTED_CODE]",
    )
    .replace(
      /([?&](?:access_token|api_key|authorization|code|key|otp|secret|signature|token)=)[^&#\s"']*/giu,
      "$1[REDACTED_QUERY_VALUE]",
    )
    .replace(
      /\b[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]{0,251}[A-Z0-9])?\.[A-Z]{2,63}\b/giu,
      "[REDACTED_EMAIL]",
    );
  for (const value of secretValues(values)) {
    safe = safe.split(value).join("[REDACTED]");
  }
  return safe;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    process.stdout.write(`${redactLine(line)}\n`);
  }
}
