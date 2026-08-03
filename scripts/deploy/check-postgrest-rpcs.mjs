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
    if (response.status !== 403 || safeRemoteCode(result?.code) !== "42501") {
      throw new Error(`STAFF_SESSION_HTTP_${response.status}_${safeRemoteCode(result?.code)}`);
    }

    const invalidToken = "0".repeat(64);
    const contextResponse = await fetch(new URL("/rest/v1/rpc/get_staff_app_session", url), {
      method: "POST",
      headers: {
        "Content-Profile": "app",
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({ p_session_token: invalidToken }),
      signal: controller.signal,
    });
    const context = await contextResponse.json().catch(() => "INVALID");
    if (!contextResponse.ok || context !== null) throw new Error(`STAFF_CONTEXT_HTTP_${contextResponse.status}`);

    const revokeResponse = await fetch(new URL("/rest/v1/rpc/revoke_staff_app_session", url), {
      method: "POST",
      headers: {
        "Content-Profile": "app",
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({ p_session_token: invalidToken }),
      signal: controller.signal,
    });
    const revoked = await revokeResponse.json().catch(() => "INVALID");
    if (!revokeResponse.ok || revoked !== 0) throw new Error(`STAFF_REVOKE_HTTP_${revokeResponse.status}`);
  } finally {
    clearTimeout(timeout);
  }
}

async function verifyAcceptanceFixtureContractAbsent(url, serviceRoleKey) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const identityPayload = {
      p_paid_member_id: null,
      p_mismatch_member_id: null,
      p_paid_order_id: null,
      p_mismatch_order_id: null,
      p_paid_relation: "FORBIDDEN",
      p_mismatch_relation: "FORBIDDEN",
      p_fixture_email: "forbidden@example.invalid",
    };
    const forbiddenContracts = [
      ["prepare_mollie_acceptance_fixture", identityPayload],
      ["get_mollie_acceptance_payment_state", { p_order_id: null, p_member_id: null }],
      ["cleanup_mollie_acceptance_fixture", identityPayload],
      ["parent_otp_members_visible", { p_member_ids: [], p_email: "forbidden@example.invalid" }],
    ];

    for (const [rpcName, payload] of forbiddenContracts) {
      const response = await fetch(new URL(`/rest/v1/rpc/${rpcName}`, url), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      const result = await response.json().catch(() => null);
      const code = safeRemoteCode(result?.code);
      if (response.status !== 404 || code !== "PGRST202") {
        throw new Error(`ACCEPTANCE_FIXTURE_RPC_VISIBLE_${response.status}_${code}`);
      }
    }
  } finally {
    clearTimeout(timeout);
  }
}

async function callRpc(
  url,
  serviceRoleKey,
  rpcName,
  payload,
  profile = "app",
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await fetch(
      new URL(`/rest/v1/rpc/${rpcName}`, url),
      {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Accept-Profile": profile,
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Profile": profile,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      },
    );
    return {
      body: await response.json().catch(() => null),
      status: response.status,
    };
  } finally {
    clearTimeout(timeout);
  }
}

async function verifySecureQrRuntimeContracts(url, serviceRoleKey) {
  const candidates = await callRpc(
    url,
    serviceRoleKey,
    "list_order_qr_identity_candidates",
    { p_limit: 1 },
  );
  if (
    candidates.status !== 200
    || !Array.isArray(candidates.body?.candidates)
  ) {
    throw new Error("QR_CANDIDATES_CONTRACT_INVALID");
  }

  const parentWorkspace = await callRpc(
    url,
    serviceRoleKey,
    "get_parent_package_workspace_v4",
    { p_token_hash: "0".repeat(64) },
    "public",
  );
  if (
    parentWorkspace.status !== 403
    || safeRemoteCode(parentWorkspace.body?.code) !== "42501"
  ) {
    throw new Error("PARENT_WORKSPACE_V4_CONTRACT_INVALID");
  }

  const health = await callRpc(
    url,
    serviceRoleKey,
    "get_operational_health_v6",
    {
      p_current_key_version: 1,
      p_current_pepper_fingerprint: "0".repeat(64),
      p_previous_key_version: null,
      p_previous_pepper_fingerprint: null,
    },
  );
  if (
    health.status !== 200
    || !health.body?.qrControl
    || typeof health.body.qrControl.keyMismatchActiveLocators !== "number"
    || typeof health.body.qrControl.keyMismatchOpenGrants !== "number"
  ) {
    throw new Error("HEALTH_V6_CONTRACT_INVALID");
  }

  const rejectedContracts = [
    [
      "register_order_qr_locator",
      {
        p_derivation_nonce: null,
        p_generation: null,
        p_key_version: null,
        p_locator_hash: null,
        p_order_id: null,
        p_pepper_fingerprint: null,
        p_request_id: null,
      },
      "22023",
    ],
    [
      "exchange_order_qr_locator_v2",
      {
        p_actor_id: null,
        p_grant_hash: "0".repeat(64),
        p_grant_key_version: 1,
        p_locator_hash: "0".repeat(64),
        p_request_id: null,
        p_staff_session_hash: "0".repeat(64),
      },
      "42501",
    ],
    [
      "commit_fulfilment_v3",
      {
        p_actor_id: null,
        p_correlation_id: null,
        p_grant_hash: "0".repeat(64),
        p_order_line_ids: [],
        p_request_id: null,
        p_staff_session_hash: "0".repeat(64),
      },
      "42501",
    ],
    [
      "expire_qr_scan_grants",
      { p_limit: 0 },
      "22023",
    ],
  ];
  for (const [rpcName, payload, expectedCode] of rejectedContracts) {
    const result = await callRpc(
      url,
      serviceRoleKey,
      rpcName,
      payload,
    );
    if (
      ![400, 403].includes(result.status)
      || safeRemoteCode(result.body?.code) !== expectedCode
    ) {
      throw new Error(`QR_RPC_CONTRACT_INVALID_${rpcName.toUpperCase()}`);
    }
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
        await verifySecureQrRuntimeContracts(url, serviceRoleKey);
        await verifyAcceptanceFixtureContractAbsent(url, serviceRoleKey);
        process.stdout.write(
          "PostgREST-contract geslaagd: sessie-, QR-, health- en ouder-RPC's zijn actueel en staging-fixture-RPC's ontbreken.\n",
        );
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
