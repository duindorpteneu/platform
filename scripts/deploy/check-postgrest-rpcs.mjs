import { pathToFileURL } from "node:url";
import {
  classifyPostgrestProbeError,
  createPostgrestHttpError,
  PostgrestProbeError,
  safeRemoteCode,
} from "./postgrest-diagnostics.mjs";

const attempts = 15;
const retryDelayMs = 2_000;
const expectedVersion = "20260803244000";

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt voor de PostgREST-contractcontrole.`);
  return value;
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
      throw createPostgrestHttpError("VERSION", response.status, code);
    }
    let contract;
    try {
      contract = await response.json();
    } catch {
      throw new PostgrestProbeError("RESPONSE_INVALID");
    }
    return contract && typeof contract === "object" ? contract : {};
  } finally {
    clearTimeout(timeout);
  }
}

async function verifyStaffSessionContract(url, serviceRoleKey) {
  const session = await callRpc(
    url,
    serviceRoleKey,
    "create_staff_app_session_for_user",
    { p_auth_user_id: null },
  );
  if (session.status !== 403 || safeRemoteCode(session.body?.code) !== "42501") {
    throw createPostgrestHttpError("STAFF_SESSION", session.status, session.body?.code);
  }

  const invalidToken = "0".repeat(64);
  const context = await callRpc(
    url,
    serviceRoleKey,
    "get_staff_app_session",
    { p_session_token: invalidToken },
  );
  if (context.status !== 200 || context.body !== null) {
    throw createPostgrestHttpError("STAFF_CONTEXT", context.status, context.body?.code);
  }

  const revoked = await callRpc(
    url,
    serviceRoleKey,
    "revoke_staff_app_session",
    { p_session_token: invalidToken },
  );
  if (revoked.status !== 200 || revoked.body !== 0) {
    throw createPostgrestHttpError("STAFF_REVOKE", revoked.status, revoked.body?.code);
  }

  const recoveryRevocation = await callRpc(
    url,
    serviceRoleKey,
    "revoke_all_staff_app_sessions_for_user",
    { p_auth_user_id: null },
  );
  if (recoveryRevocation.status !== 200 || recoveryRevocation.body !== null) {
    throw createPostgrestHttpError(
      "STAFF_RECOVERY_REVOKE",
      recoveryRevocation.status,
      recoveryRevocation.body?.code,
    );
  }
}

async function verifyAcceptanceFixtureContractAbsent(url, serviceRoleKey) {
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
    ["prepare_mollie_acceptance_fixture", identityPayload, "ACCEPTANCE_PREPARE"],
    [
      "get_mollie_acceptance_payment_state",
      { p_order_id: null, p_member_id: null },
      "ACCEPTANCE_STATE",
    ],
    ["cleanup_mollie_acceptance_fixture", identityPayload, "ACCEPTANCE_CLEANUP"],
    [
      "parent_otp_members_visible",
      { p_member_ids: [], p_email: "forbidden@example.invalid" },
      "ACCEPTANCE_PARENT_OTP",
    ],
  ];

  for (const [rpcName, payload, scope] of forbiddenContracts) {
    const result = await callRpc(url, serviceRoleKey, rpcName, payload, "public");
    const code = safeRemoteCode(result.body?.code);
    if (result.status !== 404 || code !== "PGRST202") {
      throw createPostgrestHttpError(scope, result.status, result.body?.code);
    }
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
    let body;
    try {
      body = await response.json();
    } catch {
      throw new PostgrestProbeError("RESPONSE_INVALID");
    }
    return { body, status: response.status };
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
    throw createPostgrestHttpError("QR_CANDIDATES", candidates.status, candidates.body?.code);
  }

  const parentWorkspace = await callRpc(
    url,
    serviceRoleKey,
    "get_parent_package_workspace_v6",
    { p_token_hash: "0".repeat(64) },
    "public",
  );
  if (
    parentWorkspace.status !== 403
    || safeRemoteCode(parentWorkspace.body?.code) !== "42501"
  ) {
    throw createPostgrestHttpError(
      "PARENT_WORKSPACE_V6",
      parentWorkspace.status,
      parentWorkspace.body?.code,
    );
  }

  const health = await callRpc(
    url,
    serviceRoleKey,
    "get_operational_health_v14",
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
    throw createPostgrestHttpError("HEALTH_V12", health.status, health.body?.code);
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
      "QR_REGISTER",
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
      "QR_EXCHANGE_V2",
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
      "FULFILMENT_COMMIT_V3",
    ],
    [
      "expire_qr_scan_grants",
      { p_limit: 0 },
      "22023",
      "QR_EXPIRE_GRANTS",
    ],
  ];
  for (const [rpcName, payload, expectedCode, scope] of rejectedContracts) {
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
      throw createPostgrestHttpError(scope, result.status, result.body?.code);
    }
  }
}

async function verifyStaffOnlyManagementContracts(url, serviceRoleKey) {
  const staffOnlyContracts = [
    ["get_inventory_workspace_v2", {
      p_season_id: null,
    }, "INVENTORY_WORKSPACE_V2"],
    ["get_release_feature_controls_v1", {}, "RELEASE_FEATURES_GET"],
    ["activate_release_feature_v1", {
      p_key: "dynamic_import_v2",
      p_expected_revision: "0".repeat(64),
      p_reason: "contract probe",
      p_correlation_id: null,
    }, "RELEASE_FEATURES_ACTIVATE"],
    ["pause_release_feature_v1", {
      p_key: "dynamic_import_v2",
      p_reason: "contract probe",
      p_correlation_id: null,
    }, "RELEASE_FEATURES_PAUSE"],
    ["get_action_item_workspace_v2", {
      p_season_id: null,
      p_status: null,
      p_severity: null,
      p_owner_user_id: null,
      p_only_unassigned: false,
      p_offset: 0,
      p_limit: 1,
    }, "ACTION_ITEMS_GET"],
    ["assign_action_item", {
      p_action_item_id: null,
      p_expected_revision: 0,
      p_owner_user_id: null,
      p_correlation_id: null,
    }, "ACTION_ITEMS_ASSIGN"],
    ["start_action_item", {
      p_action_item_id: null,
      p_expected_revision: 0,
      p_correlation_id: null,
    }, "ACTION_ITEMS_START"],
    ["resolve_action_item_v3", {
      p_action_item_id: null,
      p_expected_revision: 0,
      p_reason: "contract probe",
      p_correlation_id: null,
    }, "ACTION_ITEMS_RESOLVE"],
    ["dismiss_action_item", {
      p_action_item_id: null,
      p_expected_revision: 0,
      p_reason: "contract probe",
      p_correlation_id: null,
    }, "ACTION_ITEMS_DISMISS"],
    ["prepare_mail_test_delivery_v1", {
      p_request_id: null,
      p_template_key: "LOGIN_OTP",
      p_expected_content_hash: "0".repeat(64),
      p_correlation_id: null,
    }, "MAIL_TEST_PREPARE"],
    ["finalize_mail_test_delivery_v2", {
      p_delivery_id: null,
      p_outcome: "delivery_uncertain",
      p_provider_http_message_id: null,
      p_correlation_id: null,
    }, "MAIL_TEST_FINALIZE"],
    ["preflight_package_change_v1", {
      p_order_id: null,
      p_target_revision_id: null,
      p_reason: "contract probe",
      p_request_id: null,
      p_correlation_id: null,
    }, "PACKAGE_CHANGE_PREFLIGHT"],
    ["apply_package_change_v1", {
      p_request_id: null,
      p_expected_revision: "0".repeat(64),
      p_confirmation: "SWITCH_PACKAGE",
      p_correlation_id: null,
    }, "PACKAGE_CHANGE_APPLY"],
    ["get_member_saved_views", {
      p_season_id: null,
    }, "SAVED_VIEWS_GET"],
    ["save_member_saved_view", {
      p_view_id: null,
      p_season_id: null,
      p_name: "contract probe",
      p_schema_version: 1,
      p_filters: {},
    }, "SAVED_VIEWS_SAVE"],
    ["delete_member_saved_view", {
      p_view_id: null,
      p_season_id: null,
    }, "SAVED_VIEWS_DELETE"],
    ["apply_member_saved_view", {
      p_view_id: null,
      p_season_id: null,
    }, "SAVED_VIEWS_APPLY"],
    ["get_inventory_delivery_notification_proposal_v1", {
      p_delivery_draft_id: null,
    }, "DELIVERY_NOTIFICATION_GET"],
    ["get_member_detail_v5", {
      p_member_id: null,
    }, "MEMBER_DETAIL_V5"],
    ["remove_loose_order_line_v1", {
      p_order_line_id: null,
      p_reason: "contract probe",
      p_request_id: null,
      p_correlation_id: null,
    }, "LOOSE_ORDER_LINE_REMOVE"],
    ["confirm_inventory_delivery_notification_proposal_v1", {
      p_proposal_id: null,
      p_expected_revision: "0".repeat(64),
      p_excluded_item_ids: [],
      p_request_id: null,
      p_correlation_id: null,
    }, "DELIVERY_NOTIFICATION_CONFIRM"],
  ];
  for (const [rpcName, payload, scope] of staffOnlyContracts) {
    const result = await callRpc(
      url,
      serviceRoleKey,
      rpcName,
      payload,
    );
    if (
      ![401, 403].includes(result.status)
      || safeRemoteCode(result.body?.code) !== "42501"
    ) {
      throw createPostgrestHttpError(scope, result.status, result.body?.code);
    }
  }
}

export async function checkPostgrestContracts({
  url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
  serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
  maxAttempts = attempts,
  delayMs = retryDelayMs,
} = {}) {
  let lastCode = "NOT_VISIBLE";

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      const contract = await loadContractVersion(url, serviceRoleKey);
      if (contract.version === expectedVersion && contract.ready === true) {
        await verifyStaffSessionContract(url, serviceRoleKey);
        await verifySecureQrRuntimeContracts(url, serviceRoleKey);
        await verifyStaffOnlyManagementContracts(url, serviceRoleKey);
        await verifyAcceptanceFixtureContractAbsent(url, serviceRoleKey);
        process.stdout.write(
          "PostgREST-contract geslaagd: sessie-, QR-, health-, ouder- en staffbeheer-RPC's zijn actueel en staging-fixture-RPC's ontbreken.\n",
        );
        return;
      }
      lastCode = contract.version === expectedVersion ? "RPC_PRIVILEGES_INVALID" : "VERSION_NOT_VISIBLE";
    } catch (error) {
      lastCode = classifyPostgrestProbeError(error);
    }

    if (attempt < maxAttempts) await new Promise((resolve) => setTimeout(resolve, delayMs));
  }

  throw new Error(`PostgREST-contract faalde na ${maxAttempts} pogingen (${lastCode}).`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await checkPostgrestContracts();
}
