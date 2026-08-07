import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const requiredFlags = Object.freeze([
  "DYNAMIC_IMPORT_ENABLED",
  "EMAIL_ENABLED",
  "MOLLIE_ENABLED",
]);

export function assertRuntimeProvidersDisabled(source) {
  if (typeof source !== "string" || source.includes("\0")) {
    throw new Error("STAGING_RUNTIME_ENV_INVALID");
  }
  const observed = new Map();
  for (const rawLine of source.split(/\r?\n/u)) {
    if (!rawLine || rawLine.startsWith("#")) continue;
    const separator = rawLine.indexOf("=");
    if (separator < 1) throw new Error("STAGING_RUNTIME_ENV_INVALID");
    const name = rawLine.slice(0, separator);
    if (!/^[A-Z][A-Z0-9_]*$/u.test(name)) {
      throw new Error("STAGING_RUNTIME_ENV_INVALID");
    }
    if (!requiredFlags.includes(name)) continue;
    if (observed.has(name)) {
      throw new Error("STAGING_RUNTIME_PROVIDER_FLAG_DUPLICATE");
    }
    observed.set(name, rawLine.slice(separator + 1));
  }
  for (const name of requiredFlags) {
    if (observed.get(name) !== "false") {
      throw new Error("STAGING_RUNTIME_PROVIDERS_NOT_DISABLED");
    }
  }
  return true;
}

function main() {
  const target = process.argv[2];
  if (!target || process.argv.length !== 3) {
    throw new Error("STAGING_RUNTIME_ENV_PATH_REQUIRED");
  }
  assertRuntimeProvidersDisabled(readFileSync(target, "utf8"));
  console.log("Actieve stagingruntime heeft betaling, e-mail en dynamische import uitgeschakeld.");
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : "STAGING_RUNTIME_ENV_INVALID");
    process.exit(1);
  }
}
