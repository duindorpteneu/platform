const requiredRpcPaths = [
  "/rpc/get_settings_workspace_v2",
  "/rpc/update_settings_v2",
  "/rpc/create_season_v2",
];

const attempts = 15;
const retryDelayMs = 2_000;

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt voor de PostgREST-contractcontrole.`);
  return value;
}

function safeRemoteCode(value) {
  return typeof value === "string" && /^[A-Z0-9_]{2,32}$/.test(value) ? value : "UNKNOWN";
}

async function loadOpenApiDocument(url, serviceRoleKey) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await fetch(new URL("/rest/v1/", url), {
      headers: {
        Accept: "application/openapi+json",
        "Accept-Profile": "app",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      signal: controller.signal,
    });
    if (!response.ok) {
      let code = "UNKNOWN";
      try {
        code = safeRemoteCode((await response.json())?.code);
      } catch {
        // Never include an untrusted response body or credentials in deploy output.
      }
      throw new Error(`HTTP_${response.status}_${code}`);
    }
    return response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function main() {
  const url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL");
  const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
  let lastCode = "NOT_VISIBLE";

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const document = await loadOpenApiDocument(url, serviceRoleKey);
      const paths = document && typeof document === "object" && document.paths && typeof document.paths === "object"
        ? document.paths
        : {};
      const missing = requiredRpcPaths.filter((path) => !(path in paths));
      if (missing.length === 0) {
        process.stdout.write(`PostgREST-contract geslaagd: ${requiredRpcPaths.length} instellingen-RPC's zichtbaar.\n`);
        return;
      }
      lastCode = `MISSING_${missing.length}`;
    } catch (error) {
      lastCode = error instanceof Error && /^[A-Z0-9_]{2,64}$/.test(error.message)
        ? error.message
        : "REQUEST_FAILED";
    }

    if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
  }

  throw new Error(`PostgREST-contract faalde na ${attempts} pogingen (${lastCode}).`);
}

await main();
