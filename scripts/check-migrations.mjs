import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const migrationsDirectory = resolve(root, "supabase/migrations");
const filenamePattern = /^(\d{14})_([a-z0-9]+(?:_[a-z0-9]+)*)\.sql$/;
const destructiveRules = [
  ["DROP DATABASE is forbidden", /\bdrop\s+database\b/i],
  ["DROP SCHEMA is forbidden", /\bdrop\s+schema\b/i],
  ["TRUNCATE is forbidden in forward-only migrations", /(?:^|;)\s*truncate\s+(?:table\s+)?/i],
  ["disabling row-level security is forbidden", /\bdisable\s+row\s+level\s+security\b/i],
  ["granting application schemas to PUBLIC is forbidden", /\bgrant\b[\s\S]{0,300}\bon\s+(?:table|schema|function)?\s*(?:app|private)(?:\.|\b)[\s\S]{0,200}\bto\s+public\b/i],
];

function stripCommentsAndSingleQuotedStrings(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/--[^\n\r]*/g, " ")
    .replace(/'(?:''|[^'])*'/g, "''");
}

function modifiedAppliedMigrations() {
  const base = process.env.GITHUB_BASE_REF;
  if (!base) {
    return [];
  }

  try {
    const diff = execFileSync(
      "git",
      ["diff", "--name-status", `origin/${base}...HEAD`, "--", "supabase/migrations"],
      { cwd: root, encoding: "utf8" },
    );

    return diff
      .trim()
      .split("\n")
      .filter(Boolean)
      .filter((line) => /^[MD]\s/.test(line));
  } catch {
    return ["Unable to compare migrations with the pull-request base branch"];
  }
}

const files = readdirSync(migrationsDirectory)
  .filter((file) => file.endsWith(".sql"))
  .sort();
const errors = [];
const timestamps = new Map();

if (files.length === 0) {
  errors.push("No SQL migrations found");
}

for (const file of files) {
  const match = file.match(filenamePattern);
  if (!match) {
    errors.push(`${file}: expected YYYYMMDDHHMMSS_snake_case.sql`);
    continue;
  }

  const [, timestamp] = match;
  if (timestamps.has(timestamp)) {
    errors.push(`${file}: timestamp duplicates ${timestamps.get(timestamp)}`);
  } else {
    timestamps.set(timestamp, file);
  }

  const sql = readFileSync(resolve(migrationsDirectory, file), "utf8");
  if (!sql.trim()) {
    errors.push(`${file}: migration is empty`);
    continue;
  }
  if (sql.charCodeAt(0) === 0xfeff) {
    errors.push(`${file}: remove the UTF-8 BOM`);
  }

  const normalizedSql = stripCommentsAndSingleQuotedStrings(sql);
  for (const [message, pattern] of destructiveRules) {
    if (pattern.test(normalizedSql)) {
      errors.push(`${file}: ${message}`);
    }
  }
}

for (const changed of modifiedAppliedMigrations()) {
  errors.push(`Applied migration changed or deleted: ${changed}`);
}

if (errors.length > 0) {
  console.error("Migration lint failed:");
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exit(1);
}

console.log(`Migration lint passed: ${files.length} forward-only migration files checked.`);
