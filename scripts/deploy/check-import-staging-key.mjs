import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const canonicalKey = /^[A-Za-z0-9_-]{43}$/u;
const safeError = /^[A-Z0-9_]{2,64}$/u;

function required(environment, name) {
  const value = environment[name]?.trim() ?? "";
  if (!value) throw new Error(`${name}_MISSING`);
  return value;
}

export function stagingKeyFingerprint(encodedKey) {
  if (!encodedKey) return null;
  const decoded = Buffer.from(encodedKey, "base64url");
  if (
    !canonicalKey.test(encodedKey)
    || decoded.byteLength !== 32
    || decoded.toString("base64url") !== encodedKey
  ) {
    throw new Error("IMPORT_STAGING_ENCRYPTION_KEY_INVALID");
  }
  return createHash("sha256").update(decoded).digest("hex");
}

export async function assertImportStagingKey(
  environment = process.env,
  fetcher = globalThis.fetch,
) {
  const url = new URL(required(environment, "NEXT_PUBLIC_SUPABASE_URL"));
  if (url.protocol !== "https:" || url.username || url.password) {
    throw new Error("SUPABASE_URL_INVALID");
  }
  const serviceRoleKey = required(environment, "SUPABASE_SERVICE_ROLE_KEY");
  const fingerprint = stagingKeyFingerprint(
    environment.IMPORT_STAGING_ENCRYPTION_KEY?.trim() ?? "",
  );
  const response = await fetcher(
    new URL("/rest/v1/rpc/assert_dynamic_import_staging_key", url),
    {
      method: "POST",
      headers: {
        "Content-Profile": "app",
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({ p_key_fingerprint: fingerprint }),
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
    },
  );
  const result = await response.json().catch(() => null);
  if (!response.ok) {
    const message = result && typeof result === "object" && safeError.test(result.message)
      ? result.message
      : `HTTP_${response.status}`;
    throw new Error(message);
  }
  if (
    !result
    || typeof result !== "object"
    || result.compatible !== true
    || !Number.isInteger(result.pending)
    || result.pending < 0
  ) {
    throw new Error("IMPORT_STAGING_KEY_GATE_INVALID");
  }
  return { compatible: true, pending: result.pending };
}

async function main() {
  let lastError = "IMPORT_STAGING_KEY_GATE_NOT_READY";
  for (let attempt = 1; attempt <= 15; attempt += 1) {
    try {
      await assertImportStagingKey();
      process.stdout.write("Importstaging-sleutelgate geslaagd.\n");
      return;
    } catch (error) {
      lastError = error instanceof Error && safeError.test(error.message)
        ? error.message
        : "IMPORT_STAGING_KEY_GATE_FAILED";
      if (lastError === "IMPORT_STAGING_KEY_ROTATION_BLOCKED") break;
      if (attempt < 15) await new Promise((resolve) => setTimeout(resolve, 2_000));
    }
  }
  throw new Error(lastError);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    const code = error instanceof Error && safeError.test(error.message)
      ? error.message
      : "IMPORT_STAGING_KEY_GATE_FAILED";
    console.error(`Importstaging-sleutelgate geblokkeerd (${code}).`);
    process.exit(1);
  });
}
