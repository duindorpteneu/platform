import { createServer } from "node:http";
import { afterEach, describe, expect, it, vi } from "vitest";
import { checkPostgrestContracts } from "./check-postgrest-rpcs.mjs";

const servers = [];

async function serverUrl(handler) {
  const server = createServer(handler);
  servers.push(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("TEST_SERVER_ADDRESS_INVALID");
  return `http://127.0.0.1:${address.port}`;
}

function json(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(body));
}

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(
    servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))),
  );
});

describe("PostgREST releasecontract", () => {
  it("gebruikt de echte named arguments en controleert de recovery-RPC zonder mutatie", async () => {
    const calls = [];
    const baseUrl = await serverUrl((request, response) => {
      let rawBody = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => { rawBody += chunk; });
      request.on("end", () => {
        const rpcName = request.url?.split("/").at(-1) ?? "";
        const body = rawBody ? JSON.parse(rawBody) : null;
        calls.push({
          acceptProfile: request.headers["accept-profile"],
          body,
          contentProfile: request.headers["content-profile"],
          rpcName,
        });

        if (rpcName === "get_settings_rpc_contract_version") {
          json(response, 200, { ready: true, version: "20260803244000" });
        } else if (rpcName === "create_staff_app_session_for_user") {
          json(response, 403, { code: "42501" });
        } else if (rpcName === "get_staff_app_session") {
          json(response, 200, null);
        } else if (rpcName === "revoke_staff_app_session") {
          json(response, 200, 0);
        } else if (rpcName === "revoke_all_staff_app_sessions_for_user") {
          json(response, 200, null);
        } else if (rpcName === "list_order_qr_identity_candidates") {
          json(response, 200, { candidates: [] });
        } else if (rpcName === "get_parent_package_workspace_v6") {
          json(response, 403, { code: "42501" });
        } else if (rpcName === "get_operational_health_v12") {
          json(response, 200, {
            qrControl: {
              keyMismatchActiveLocators: 0,
              keyMismatchOpenGrants: 0,
            },
          });
        } else if (["register_order_qr_locator", "expire_qr_scan_grants"].includes(rpcName)) {
          json(response, 400, { code: "22023" });
        } else if (["exchange_order_qr_locator_v2", "commit_fulfilment_v3"].includes(rpcName)) {
          json(response, 403, { code: "42501" });
        } else if (request.headers["content-profile"] === "public") {
          json(response, 404, { code: "PGRST202" });
        } else {
          json(response, 403, { code: "42501" });
        }
      });
    });
    vi.spyOn(process.stdout, "write").mockImplementation(() => true);

    await expect(checkPostgrestContracts({
      url: baseUrl,
      serviceRoleKey: "test-service-role-key",
      maxAttempts: 1,
      delayMs: 0,
    })).resolves.toBeUndefined();

    const confirmation = calls.find(
      (call) => call.rpcName === "confirm_inventory_delivery_notification_proposal_v1",
    );
    expect(confirmation).toMatchObject({
      body: {
        p_correlation_id: null,
        p_excluded_item_ids: [],
        p_expected_revision: "0".repeat(64),
        p_proposal_id: null,
        p_request_id: null,
      },
      acceptProfile: "app",
      contentProfile: "app",
    });
    expect(confirmation.body).not.toHaveProperty("p_selected_item_ids");
    expect(calls).toContainEqual(expect.objectContaining({
      body: { p_season_id: null },
      acceptProfile: "app",
      contentProfile: "app",
      rpcName: "get_inventory_workspace_v2",
    }));
    expect(calls).toContainEqual(expect.objectContaining({
      body: { p_auth_user_id: null },
      acceptProfile: "app",
      contentProfile: "app",
      rpcName: "revoke_all_staff_app_sessions_for_user",
    }));

    for (const call of calls) {
      const expectedProfile = [
        "get_parent_package_workspace_v6",
        "prepare_mollie_acceptance_fixture",
        "get_mollie_acceptance_payment_state",
        "cleanup_mollie_acceptance_fixture",
        "parent_otp_members_visible",
      ].includes(call.rpcName) ? "public" : "app";
      expect(call.contentProfile, call.rpcName).toBe(expectedProfile);
      if (call.rpcName === "get_settings_rpc_contract_version") {
        expect(call.acceptProfile).toBeUndefined();
      } else {
        expect(call.acceptProfile, call.rpcName).toBe(expectedProfile);
      }
    }
  });

  it("weigert een HTTP 200 zonder geldige JSON ook voor een null-contract", async () => {
    const baseUrl = await serverUrl((request, response) => {
      request.resume();
      request.on("end", () => {
        const rpcName = request.url?.split("/").at(-1) ?? "";
        if (rpcName === "get_settings_rpc_contract_version") {
          json(response, 200, { ready: true, version: "20260803244000" });
        } else if (rpcName === "create_staff_app_session_for_user") {
          json(response, 403, { code: "42501" });
        } else {
          response.writeHead(200, { "Content-Type": "text/html" });
          response.end("ONGELDIGE_RESPONSE_MARKER");
        }
      });
    });

    await expect(checkPostgrestContracts({
      url: baseUrl,
      serviceRoleKey: "test-service-role-key",
      maxAttempts: 1,
      delayMs: 0,
    })).rejects.toThrow("(RESPONSE_INVALID)");
  });
});
