import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const KEY_PATTERN = /^[A-Z][A-Z0-9_]*$/u;
const SHA_PATTERN = /^[a-f0-9]{40}$/u;
const DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/u;

function decodeHistoricalQuotedValue(value) {
  if (!value.startsWith('"')) return value;
  if (value.length < 2 || !value.endsWith('"')) {
    throw new Error("Legacy runtime bevat een onafgesloten quoted waarde");
  }
  const inner = value.slice(1, -1);
  let decoded = "";
  for (let index = 0; index < inner.length; index += 1) {
    const character = inner[index];
    if (character !== "\\") {
      decoded += character;
      continue;
    }
    const escaped = inner[index + 1];
    if (escaped !== "\\" && escaped !== '"') {
      throw new Error("Legacy runtime bevat een onbekende escape");
    }
    decoded += escaped;
    index += 1;
  }
  return decoded;
}

function assertSafeValue(value) {
  if (/[\0\r\n]/u.test(value)) {
    throw new Error("Legacy runtime bevat een onveilige controlwaarde");
  }
}

export function parseLegacyRuntime(source) {
  if (typeof source !== "string") {
    throw new Error("Legacy runtime moet tekst zijn");
  }
  const entries = new Map();
  for (const line of source.split(/\r?\n/u)) {
    if (!line) continue;
    const separator = line.indexOf("=");
    if (separator < 1) {
      throw new Error("Legacy runtime bevat een ongeldige regel");
    }
    const key = line.slice(0, separator);
    if (!KEY_PATTERN.test(key) || entries.has(key)) {
      throw new Error("Legacy runtime bevat een ongeldige of dubbele sleutel");
    }
    const value = decodeHistoricalQuotedValue(line.slice(separator + 1));
    assertSafeValue(value);
    entries.set(key, value);
  }
  if (entries.size === 0) {
    throw new Error("Legacy runtime is leeg");
  }
  return entries;
}

export function buildLegacyRuntime(
  source,
  { environment, releaseSha, artifactDigest },
) {
  if (
    !["staging", "production"].includes(environment)
    || !SHA_PATTERN.test(releaseSha ?? "")
    || !DIGEST_PATTERN.test(artifactDigest ?? "")
  ) {
    throw new Error("Legacy runtime-doelidentiteit is ongeldig");
  }
  const entries = parseLegacyRuntime(source);
  entries.set("APP_ENVIRONMENT", environment);
  entries.set("RELEASE_SHA", releaseSha);
  entries.set("RELEASE_ARTIFACT_DIGEST", artifactDigest);
  entries.set("EMAIL_ENABLED", "false");
  entries.set("MOLLIE_ENABLED", "false");
  entries.set("DYNAMIC_IMPORT_ENABLED", "false");
  return `${[...entries]
    .map(([key, value]) => {
      assertSafeValue(value);
      return `${key}=${value}`;
    })
    .join("\n")}\n`;
}

async function main() {
  const [sourcePath, targetPath, environment, releaseSha, artifactDigest] =
    process.argv.slice(2);
  if (
    !sourcePath
    || !targetPath
    || path.resolve(sourcePath) === path.resolve(targetPath)
  ) {
    throw new Error(
      "Gebruik normalize-legacy-runtime.mjs <bron> <doel> <omgeving> <sha> <artifactdigest>",
    );
  }
  const output = buildLegacyRuntime(
    await readFile(sourcePath, "utf8"),
    { environment, releaseSha, artifactDigest },
  );
  const target = path.resolve(targetPath);
  const temporary = `${target}.normalized-${process.pid}`;
  await writeFile(temporary, output, { mode: 0o600, flag: "wx" });
  await chmod(temporary, 0o600);
  await rename(temporary, target);
  await chmod(target, 0o600);
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Legacy runtime kon niet worden genormaliseerd"}\n`,
    );
    process.exitCode = 1;
  });
}
