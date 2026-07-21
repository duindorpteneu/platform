const attempts = 15;
const retryDelayMs = 2_000;
const expectedVersion = "20260720142000";

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt voor de PostgREST-contractcontrole.`);
  return value;
}

function safeRemoteCode(value) {
  return typeof value === "string" && /^[A-Z0-9_]{2,32}$/.test(value) ? value : "UNKNOWN";
}

async function loadContractVersion(url, serviceRoleKey) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await fetch(new URL("/rest/v1/rpc/get_settings_rpc_contract_version", url), {
      method: "POST",
      headers: {
        "Content-Profile": "app",
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: "{}",
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
    const contract = await response.json();
    return contract && typeof contract === "object" ? contract : {};
  } finally {
    clearTimeout(timeout);
  }
}

async function verifyStaffSessionContract(url, serviceRoleKey) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await fetch(new URL("/rest/v1/rpc/create_staff_app_session_for_user", url), {
      method: "POST",
      headers: {
        "Content-Profile": "app",
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({ p_auth_user_id: null }),
      signal: controller.signal,
    });
    const result = await response.json().catch(() => null);
    if (response.status === 403 && safeRemoteCode(result?.code) === "42501") return;
    throw new Error(`STAFF_SESSION_HTTP_${response.status}_${safeRemoteCode(result?.code)}`);
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
      const contract = await loadContractVersion(url, serviceRoleKey);
      if (contract.version === expectedVersion && contract.ready === true) {
        await verifyStaffSessionContract(url, serviceRoleKey);
        process.stdout.write("PostgREST-contract geslaagd: instellingen-RPC's zijn actueel en uitvoerbaar.\n");
        return;
      }
      lastCode = contract.version === expectedVersion ? "RPC_PRIVILEGES_INVALID" : "VERSION_NOT_VISIBLE";
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
