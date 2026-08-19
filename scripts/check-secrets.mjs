import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, extname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const maximumBytes = 2 * 1024 * 1024;
const forbiddenEnvironmentFiles = /^\.env(?:\.(?:local|staging|production|development|test))?$/;
const textExtensions = new Set([
  "",
  ".css",
  ".csv",
  ".env",
  ".html",
  ".js",
  ".json",
  ".jsx",
  ".md",
  ".mjs",
  ".sql",
  ".svg",
  ".toml",
  ".ts",
  ".tsx",
  ".txt",
  ".yaml",
  ".yml",
]);

const tokenRules = [
  ["private key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],
  ["AWS access key", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g],
  ["GitHub token", /\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}\b/g],
  ["Slack token", /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g],
  ["SendGrid API key", /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g],
  ["Mollie API key", /\b(?:live|test)_[A-Za-z0-9]{20,}\b/g],
  ["Supabase secret key", /\bsb_secret_[A-Za-z0-9_-]{20,}\b/g],
  ["Stripe secret key", /\bsk_(?:live|test)_[A-Za-z0-9]{20,}\b/g],
];

const sensitiveAssignment = new RegExp(
  String.raw`^\s*(?:export\s+)?(?:SUPABASE_SECRET_KEY|PARENT_TOKEN_PEPPER|QR_TOKEN_PEPPER|QR_TOKEN_PREVIOUS_PEPPER|CRON_SECRET|IMPORT_STAGING_ENCRYPTION_KEY|OPERATIONS_HEARTBEAT_URL|MOLLIE_API_KEY|SENDGRID_API_KEY|SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|SES_SNS_TOPIC_ARN|DATABASE_URL|POSTGRES_PASSWORD|CLIENT_SECRET|PRIVATE_KEY)\s*=\s*(.+?)\s*$`,
  "i",
);

function trackedAndUnignoredFiles() {
  const output = execFileSync(
    "git",
    ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    { cwd: root, encoding: "utf8" },
  );

  return output.split("\0").filter(Boolean);
}

function isPlaceholder(value) {
  const normalized = value.trim().replace(/^['"]|['"]$/g, "").trim();
  return (
    normalized === "" ||
    /^(?:null|undefined)$/i.test(normalized) ||
    /^(?:<[^>]+>|\$\{[^}]+\})$/.test(normalized) ||
    /(?:example|placeholder|replace[_-]?me|your[_-]|dummy|x{3,})/i.test(normalized) ||
    /^(?:false|true)$/.test(normalized)
  );
}

function lineNumber(text, index) {
  return text.slice(0, index).split("\n").length;
}

const findings = [];

for (const relativePath of trackedAndUnignoredFiles()) {
  const path = resolve(root, relativePath);
  const name = basename(relativePath);

  if (!existsSync(path)) continue;

  if (forbiddenEnvironmentFiles.test(name) && !name.endsWith(".example")) {
    findings.push(`${relativePath}: tracked environment file`);
  }

  if (!textExtensions.has(extname(relativePath).toLowerCase()) || statSync(path).size > maximumBytes) {
    continue;
  }

  const buffer = readFileSync(path);
  if (buffer.includes(0)) {
    continue;
  }

  const text = buffer.toString("utf8");

  for (const [label, pattern] of tokenRules) {
    pattern.lastIndex = 0;
    for (const match of text.matchAll(pattern)) {
      findings.push(`${relativePath}:${lineNumber(text, match.index)}: ${label}`);
    }
  }

  for (const [index, line] of text.split(/\r?\n/).entries()) {
    const match = line.match(sensitiveAssignment);
    if (match && !isPlaceholder(match[1])) {
      findings.push(`${relativePath}:${index + 1}: populated sensitive setting`);
    }
  }
}

if (findings.length > 0) {
  console.error("Secret scan failed. Potential credentials were found (values are intentionally redacted):");
  for (const finding of [...new Set(findings)].sort()) {
    console.error(`- ${finding}`);
  }
  process.exit(1);
}

console.log("Secret scan passed: no high-confidence credentials or tracked runtime environment files found.");
