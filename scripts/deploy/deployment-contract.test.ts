import { execFileSync, spawnSync } from "node:child_process";
import {
  createHash,
  generateKeyPairSync,
} from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const repositoryRoot = path.resolve(import.meta.dirname, "../..");
const configureRuntime = path.join(import.meta.dirname, "configure-runtime.mjs");
const releaseManifest = path.join(import.meta.dirname, "release-manifest.mjs");
const releaseSha = "a".repeat(40);
const temporaryDirectories: string[] = [];

function jwt(role: "anon" | "service_role", ref: string) {
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ role, ref, exp: 4_102_444_800 })}.signature`;
}

function runtimeEnvironment(environment: "staging" | "production") {
  const staging = environment === "staging";
  const ref = staging ? "dxbdjtbyghsovlrdcwcr" : "wobcbufmmputydtzemyu";
  const host = staging ? "duindorpsv.dgwebservices.nl" : "duindorp.dgwebservices.nl";
  return {
    ...process.env,
    DEPLOY_ENVIRONMENT: environment,
    RELEASE_SHA: releaseSha,
    RELEASE_ARTIFACT_DIGEST: `sha256:${"b".repeat(64)}`,
    RUNTIME_DIRECTORY: `/srv/apps/duindorpteneu/${environment}`,
    COMPOSE_PROJECT_NAME: `duindorpteneu-${environment}`,
    APP_HOST: host,
    APP_BIND_PORT: staging ? "14000" : "24000",
    NEXT_PUBLIC_APP_URL: `https://${host}`,
    SUPABASE_PROJECT_REF: ref,
    NEXT_PUBLIC_SUPABASE_URL: `https://${ref}.supabase.co`,
    SUPABASE_JWKS: JSON.stringify({ keys: [{
      kty: "EC", crv: "P-256", alg: "ES256", kid: `${ref}-test-key`,
      x: "A".repeat(43), y: "B".repeat(43),
    }] }),
    NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt("anon", ref),
    SUPABASE_SERVICE_ROLE_KEY: jwt("service_role", ref),
    SUPABASE_DB_URL: `postgresql://postgres:password@db.${ref}.supabase.co:5432/postgres?sslmode=require`,
    NEXT_SERVER_ACTIONS_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64"),
    PARENT_TOKEN_PEPPER: "p".repeat(32),
    QR_TOKEN_PEPPER: Buffer.alloc(32, 8).toString("base64url"),
    QR_TOKEN_PEPPER_VERSION: "1",
    CRON_SECRET: "c".repeat(32),
    DYNAMIC_IMPORT_ENABLED: "false",
    IMPORT_RAW_RETENTION_HOURS: "24",
    ...(staging ? {} : { OPERATIONS_HEARTBEAT_URL: "https://monitor.example/ping-secret" }),
    MOLLIE_ENABLED: "false",
    EMAIL_ENABLED: "false",
    EMAIL_PROVIDER: "sendgrid",
  };
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("deployment environment isolation", () => {
  it.each(["staging", "production"] as const)("accepts canonical %s identity", (environment) => {
    expect(() => execFileSync(process.execPath, [configureRuntime, "validate"], {
      env: runtimeEnvironment(environment),
      stdio: "pipe",
    })).not.toThrow();
  });

  it("allows a live Mollie key only on the canonical public club origin", () => {
    const staging = {
      ...runtimeEnvironment("staging"),
      MOLLIE_ENABLED: "true",
      MOLLIE_API_KEY: "live_public-club-runtime",
    };
    expect(() => execFileSync(process.execPath, [configureRuntime, "validate"], {
      env: staging,
      stdio: "pipe",
    })).not.toThrow();

    const invalid = spawnSync(process.execPath, [configureRuntime, "validate"], {
      env: { ...staging, MOLLIE_API_KEY: "invalid_key" },
      encoding: "utf8",
    });
    expect(invalid.status).toBe(1);
    expect(invalid.stderr).toContain("MOLLIE_API_KEY");
  });

  it("rejects production Supabase identity in staging", () => {
    const staging = runtimeEnvironment("staging");
    const production = runtimeEnvironment("production");
    const result = spawnSync(process.execPath, [configureRuntime, "validate"], {
      env: {
        ...staging,
        SUPABASE_PROJECT_REF: production.SUPABASE_PROJECT_REF,
        NEXT_PUBLIC_SUPABASE_URL: production.NEXT_PUBLIC_SUPABASE_URL,
        NEXT_PUBLIC_SUPABASE_ANON_KEY: production.NEXT_PUBLIC_SUPABASE_ANON_KEY,
        SUPABASE_SERVICE_ROLE_KEY: production.SUPABASE_SERVICE_ROLE_KEY,
        SUPABASE_DB_URL: production.SUPABASE_DB_URL,
      },
      encoding: "utf8",
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("SUPABASE_PROJECT_REF");
  });

  it("requires a valid local ES256 JWKS in runtime configuration", () => {
    const environment = runtimeEnvironment("staging");
    environment.SUPABASE_JWKS = JSON.stringify({ keys: [{ kty: "RSA", alg: "RS256", kid: "wrong" }] });
    const result = spawnSync(process.execPath, [configureRuntime, "validate"], { env: environment, encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("SUPABASE_JWKS");
  });

  it("keeps public browser configuration runtime-injected", () => {
    const dockerfile = readFileSync(path.join(repositoryRoot, "Dockerfile"), "utf8");
    const dockerignore = readFileSync(path.join(repositoryRoot, ".dockerignore"), "utf8");
    const layout = readFileSync(path.join(repositoryRoot, "src/app/layout.tsx"), "utf8");
    expect(dockerfile).not.toMatch(/\b(?:ARG|ENV)\s+NEXT_PUBLIC_/);
    expect(dockerignore.split(/\r?\n/)).toContain(".release");
    expect(layout).toContain("globalThis.__DUINDORP_RUNTIME_CONFIG__");
  });

  it("ships a digest-pinned shell-less Node 22 runtime without package managers", () => {
    const dockerfile = readFileSync(path.join(repositoryRoot, "Dockerfile"), "utf8");
    const compose = readFileSync(path.join(repositoryRoot, "deploy/compose.vps.yml"), "utf8");
    const runtimeMarker = "FROM gcr.io/distroless/nodejs22-debian13:nonroot@sha256:";
    const runtimeStart = dockerfile.indexOf(runtimeMarker);
    expect(runtimeStart).toBeGreaterThan(-1);
    const runtimeStage = dockerfile.slice(runtimeStart);
    expect(runtimeStage.split(/\r?\n/, 1)[0]).toMatch(
      /^FROM gcr\.io\/distroless\/nodejs22-debian13:nonroot@sha256:[a-f0-9]{64} AS runtime$/,
    );
    expect(runtimeStage).toContain("USER 65532:65532");
    expect(runtimeStage).toContain('ENTRYPOINT ["/nodejs/bin/node"]');
    expect(runtimeStage).toContain('CMD ["scripts/runtime/body-limit-gateway.mjs"]');
    expect(runtimeStage).toContain(
      "/app/scripts/runtime/body-limit-gateway.mjs ./scripts/runtime/body-limit-gateway.mjs",
    );
    expect(runtimeStage).toContain(
      "/app/deploy/edge-body-probe-contract.json ./deploy/edge-body-probe-contract.json",
    );
    expect(runtimeStage).toContain("@img+sharp-libvips-linux-x64@1.3.0");
    expect(runtimeStage).not.toMatch(/^RUN\s/m);
    expect(runtimeStage).not.toMatch(
      /^(?:ENTRYPOINT|CMD)\s.*\b(?:corepack|npm|pnpm|yarn)\b/m,
    );
    expect(compose.match(/- \/nodejs\/bin\/node/g)).toHaveLength(2);
    expect(compose).toMatch(/scheduler:[\s\S]*?command:\s*\n\s*- operations-scheduler\.mjs/);
    expect(compose).not.toMatch(/scheduler:[\s\S]*?command:\s*\n\s*- node/);
    expect(compose).toContain("fetch('http://127.0.0.1:3000/api/live')");
    expect(compose).toContain(
      "r.status===404?fetch('http://127.0.0.1:3000/'):r",
    );
    expect(compose).not.toContain("fetch('http://127.0.0.1:3000/api/health')");
  });

  it("accepts the staging Mollie profile id from a protected secret or variable", () => {
    const workflow = readFileSync(
      path.join(repositoryRoot, ".github/workflows/staging-mollie-acceptance.yml"),
      "utf8",
    );
    expect(workflow).toContain(
      "MOLLIE_PROFILE_ID: ${{ secrets.MOLLIE_PROFILE_ID || vars.MOLLIE_PROFILE_ID }}",
    );
    expect(workflow).toContain("group: deploy-duindorpteneu-staging");
  });

  it("keeps the hosted PostgREST schema list aligned with local Supabase", () => {
    const config = readFileSync(path.join(repositoryRoot, "supabase/config.toml"), "utf8");
    const migration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260719100000_expose_app_data_api.sql"),
      "utf8",
    );
    expect(config).toContain('schemas = ["public", "graphql_public", "app"]');
    expect(migration).toContain(
      "alter role authenticator set pgrst.db_schemas = 'public, graphql_public, app'",
    );
    expect(migration).not.toMatch(/\bprivate\b[^\n]*pgrst\.db_schemas/i);
  });

  it("refreshes and verifies the settings RPC contract before application activation", () => {
    const baselineRefreshMigration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260720142000_refresh_postgrest_settings_contract.sql"),
      "utf8",
    );
    const refreshMigration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260803244000_canonical_published_branding.sql"),
      "utf8",
    );
    const releaseRefreshMigration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260811130000_refresh_postgrest_release_contract.sql"),
      "utf8",
    );
    const deployScript = readFileSync(path.join(repositoryRoot, "scripts/deploy-vps.sh"), "utf8");
    const contractScript = readFileSync(path.join(repositoryRoot, "scripts/deploy/check-postgrest-rpcs.mjs"), "utf8");
    expect(baselineRefreshMigration).not.toMatch(
      /\b(?:insert|update|delete|truncate)\b/i,
    );
    expect(refreshMigration).toContain("notify pgrst, 'reload schema'");
    expect(
      releaseRefreshMigration.replace(/^--.*$/gm, "").trim(),
    ).toBe("notify pgrst, 'reload schema';");
    expect(refreshMigration).toContain("get_settings_rpc_contract_version");
    expect(refreshMigration).toContain("'get_settings_workspace_v3'");
    expect(refreshMigration).toContain("'update_settings_v3'");
    expect(refreshMigration).toContain("'create_season_v3'");
    expect(refreshMigration).toMatch(
      /grant execute on function app\.get_settings_rpc_contract_version\(\)\s+to service_role/,
    );
    expect(contractScript).toContain("/rest/v1/rpc/get_settings_rpc_contract_version");
    expect(contractScript).toContain('"create_staff_app_session_for_user"');
    expect(contractScript).toContain('"get_staff_app_session"');
    expect(contractScript).toContain('"revoke_staff_app_session"');
    expect(contractScript).toContain('"revoke_all_staff_app_sessions_for_user"');
    expect(contractScript).toContain('"list_order_qr_identity_candidates"');
    expect(contractScript).toContain('"get_parent_package_workspace_v6"');
    expect(contractScript).toContain('"get_member_detail_v5"');
    expect(contractScript).toContain('"remove_loose_order_line_v1"');
    expect(contractScript).toContain('"get_operational_health_v13"');
    expect(contractScript).toContain('"register_order_qr_locator"');
    expect(contractScript).toContain('"exchange_order_qr_locator_v2"');
    expect(contractScript).toContain('"commit_fulfilment_v3"');
    expect(contractScript).toContain('"expire_qr_scan_grants"');
    expect(contractScript).toContain('"get_release_feature_controls_v1"');
    expect(contractScript).toContain('"activate_release_feature_v1"');
    expect(contractScript).toContain('"pause_release_feature_v1"');
    expect(contractScript).toContain('"get_action_item_workspace_v2"');
    expect(contractScript).toContain('"assign_action_item"');
    expect(contractScript).toContain('"start_action_item"');
    expect(contractScript).toContain('"resolve_action_item_v3"');
    expect(contractScript).toContain('"dismiss_action_item"');
    expect(contractScript).toContain('"prepare_mollie_acceptance_fixture"');
    expect(contractScript).toContain('"get_mollie_acceptance_payment_state"');
    expect(contractScript).toContain('"cleanup_mollie_acceptance_fixture"');
    expect(contractScript).toContain('"parent_otp_members_visible"');
    expect(contractScript).toContain('result.status !== 404 || code !== "PGRST202"');
    expect(contractScript).toContain("p_excluded_item_ids: []");
    expect(contractScript).not.toContain("p_selected_item_ids");
    expect(contractScript).toContain('safeRemoteCode(result.body?.code) !== "42501"');
    expect(contractScript).not.toContain("get_settings_workspace_v2");
    expect(deployScript).toContain("DUINDORP_RUNTIME_PROBE_NONCE");
    expect(deployScript).toContain("Actieve runtime bevat niet de verwachte PARENT_TOKEN_PEPPER");
    expect(deployScript).toContain("Actieve runtime bevat niet de verwachte QR_TOKEN_PEPPER");
    expect(deployScript).toContain("Actieve runtime bevat niet de verwachte QR_TOKEN_PEPPER_VERSION");
    expect(deployScript).toContain("Actieve runtime bevat niet de verwachte QR_TOKEN_PREVIOUS_PEPPER_VERSION");
    expect(deployScript).toContain("Actieve runtime bevat onverwacht een vorige QR-sleutel");
    expect(deployScript).toContain("Actieve runtime bevat niet de verwachte importstaging-sleutel");
    expect(deployScript).toContain("source scripts/deploy/failure-guard.sh");
    const postgrestGate = deployScript.indexOf("node scripts/deploy/check-postgrest-rpcs.mjs");
    const importKeyGate = deployScript.indexOf("node scripts/deploy/check-import-staging-key.mjs");
    expect(postgrestGate)
      .toBeGreaterThan(deployScript.indexOf('"$supabase_cli" db push --db-url "$SUPABASE_DB_URL" --yes'));
    expect(postgrestGate).toBeLessThan(deployScript.indexOf("activated=true"));
    expect(importKeyGate).toBeGreaterThan(postgrestGate);
    expect(importKeyGate).toBeLessThan(deployScript.indexOf("activated=true"));
    expect(deployScript).toContain(
      'check_with_retries "http://127.0.0.1:${expected_port}"',
    );
    expect(deployScript).toContain(
      'check_with_retries "https://${expected_host}"',
    );
    expect(
      deployScript.match(/"\$RELEASE_SHA" "\$expected_artifact_digest" 100/g),
    ).toHaveLength(2);
  });

  it("blocks staging and production until the public proxy rejects chunked oversize bodies", () => {
    const deployScript = readFileSync(path.join(repositoryRoot, "scripts/deploy-vps.sh"), "utf8");
    const probeScript = readFileSync(
      path.join(repositoryRoot, "scripts/deploy/check-edge-body-limits.mjs"),
      "utf8",
    );
    const caddyIntegration = readFileSync(
      path.join(repositoryRoot, "scripts/deploy/test-edge-body-limits-caddy.mjs"),
      "utf8",
    );
    const nextIntegration = readFileSync(
      path.join(repositoryRoot, "scripts/deploy/test-edge-body-probe-next.mjs"),
      "utf8",
    );
    const runtimeGateway = readFileSync(
      path.join(repositoryRoot, "scripts/runtime/body-limit-gateway.mjs"),
      "utf8",
    );
    const runtimeGatewayIntegration = readFileSync(
      path.join(repositoryRoot, "scripts/deploy/test-runtime-body-gateway.mjs"),
      "utf8",
    );
    const nextConfig = readFileSync(path.join(repositoryRoot, "next.config.ts"), "utf8");
    const caddyReference = readFileSync(
      path.join(repositoryRoot, "deploy/caddy/duindorp-tenueportaal.caddy.example"),
      "utf8",
    );
    const probeContract = JSON.parse(readFileSync(
      path.join(repositoryRoot, "deploy/edge-body-probe-contract.json"),
      "utf8",
    )) as { probes: { name: string; path: string; maxBytes: number }[] };
    const edgeGate = deployScript.indexOf('node scripts/deploy/check-edge-body-limits.mjs "$environment"');
    const internalHealth = deployScript.indexOf('check_with_retries "http://127.0.0.1:${expected_port}"');
    const publicHealth = deployScript.indexOf('check_with_retries "https://${expected_host}"');
    const schedulerHealth = deployScript.indexOf('check_scheduler_with_retries "$image_tag"', edgeGate);
    const revisionPublication = deployScript.indexOf('mv -f -- "$temp_revision" "${runtime_directory}/REVISION"', edgeGate);
    const releasePublication = deployScript.indexOf('mv -f -- "$temp_manifest" "${runtime_directory}/RELEASE_MANIFEST"', edgeGate);
    const deactivation = deployScript.indexOf("activated=false", edgeGate);
    expect(edgeGate).toBeGreaterThan(internalHealth);
    expect(edgeGate).toBeGreaterThan(publicHealth);
    expect(edgeGate).toBeLessThan(schedulerHealth);
    expect(edgeGate).toBeLessThan(revisionPublication);
    expect(edgeGate).toBeLessThan(releasePublication);
    expect(edgeGate).toBeLessThan(deactivation);
    expect(deployScript.indexOf("trap 'rollback $?' ERR")).toBeLessThan(edgeGate);
    expect(deployScript).toContain("for attempt in $(seq 1 100); do");
    expect(deployScript).toContain('[[ "$attempt" == 100 ]] && return 1');
    expect(probeScript).toContain('"Content-Type": "application/octet-stream"');
    expect(probeScript).toContain('duplex: "half"');
    expect(probeScript).not.toContain("Authorization");
    expect(probeContract.probes).toEqual([
      { name: "standard-api", path: "/api/catalog/articles", maxBytes: 128_000 },
      { name: "email-bulk", path: "/api/email/bulk", maxBytes: 384_000 },
      { name: "sendgrid-webhook", path: "/api/webhooks/sendgrid", maxBytes: 2_000_000 },
      { name: "sportlink-import", path: "/api/imports/uploads", maxBytes: 12_000_000 },
    ]);
    for (const limit of ["128KB", "384KB", "2MB", "12MB"]) {
      expect(caddyReference).toContain(`max_size ${limit}`);
    }
    for (const route of [
      "/api/email/bulk",
      "/api/email/v2/campaigns",
      "/api/webhooks/sendgrid",
      "/api/imports/uploads",
      "/api/imports/preview",
      "/api/imports/commit",
    ]) expect(caddyReference).toContain(route);
    expect(caddyReference).not.toMatch(/not path[^\n]*\/api\/catalog\/articles/);
    expect(caddyIntegration).toContain("caddy:2.10.2@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83");
    expect(caddyIntegration).toContain("await assertEdgeBodyLimits");
    expect(caddyIntegration).toContain("CADDY_TEST_RAISED_LIMIT_NOT_DETECTED");
    expect(caddyIntegration).toContain('"--cap-drop", "ALL"');
    expect(caddyIntegration).not.toContain("--cap-add");
    expect(caddyIntegration).toContain('["SIGINT", 130]');
    expect(caddyIntegration).toContain("CADDY_TEST_CLEANUP_FAILED");
    expect(nextConfig).toContain("middlewareClientMaxBodySize: 12_000_001");
    expect(nextIntegration).toContain('"X-Forwarded-Host": publicHost');
    expect(nextIntegration).toContain('"Transfer-Encoding": "chunked"');
    expect(nextIntegration).toContain('path.resolve(".next/standalone")');
    expect(nextIntegration).toContain("NEXT_PROBE_STANDALONE_INVALID");
    expect(nextIntegration).toContain("sportlink.maxBytes + 1");
    expect(nextIntegration).toContain("Request body exceeded");
    expect(runtimeGateway).toContain("createBodyLimitGateway");
    expect(runtimeGateway).toContain('upstreamHost: rawOptions.upstreamHost ?? "127.0.0.1"');
    expect(runtimeGateway).toContain('pathname === "/api/email/v2/campaigns"');
    expect(runtimeGatewayIntegration).toContain("await assertEdgeBodyLimits");
    expect(runtimeGatewayIntegration).toContain("body_limit_gateway_started");
    const ciWorkflow = readFileSync(
      path.join(repositoryRoot, ".github/workflows/ci.yml"),
      "utf8",
    );
    expect(ciWorkflow).toContain("pnpm test:edge-runtime");
    expect(ciWorkflow.indexOf("pnpm build"))
      .toBeLessThan(ciWorkflow.indexOf("pnpm test:edge-runtime"));
    expect(deployScript).toContain(
      'node scripts/deploy/check-edge-body-limits.mjs "$environment"',
    );
  });

  it("refreshes the service-only staff session RPC without mutating business data", () => {
    const migration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260721140000_refresh_staff_session_contract.sql"),
      "utf8",
    );
    expect(migration).toContain("grant execute on function app.create_staff_app_session_for_user(uuid) to service_role");
    expect(migration).toContain("notify pgrst, 'reload schema'");
    expect(migration).not.toMatch(/\b(?:insert|update|delete|truncate)\b/i);
  });

  it("refreshes every service-only opaque staff runtime function", () => {
    const migration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260721150000_refresh_staff_runtime_session_contract.sql"),
      "utf8",
    );
    for (const signature of [
      "create_staff_app_session_for_user(uuid)",
      "get_staff_app_session(text)",
      "revoke_staff_app_session(text)",
    ]) expect(migration).toContain(`grant execute on function app.${signature} to service_role`);
    expect(migration).toContain("notify pgrst, 'reload schema'");
  });

  it("removes every acceptance-only RPC without cascade or product fixture state", () => {
    const migration = readFileSync(
      path.join(
        repositoryRoot,
        "supabase/migrations/20260802170000_remove_product_mollie_acceptance_fixtures.sql",
      ),
      "utf8",
    );
    const acceptance = readFileSync(
      path.join(repositoryRoot, "scripts/providers/mollie-staging-acceptance.mjs"),
      "utf8",
    );
    for (const functionName of [
      "prepare_mollie_acceptance_fixture",
      "get_mollie_acceptance_payment_state",
      "cleanup_mollie_acceptance_fixture",
      "is_mollie_acceptance_identity",
      "parent_otp_members_visible",
    ]) {
      expect(migration).toContain(functionName);
      expect(acceptance).not.toContain(`"${functionName}"`);
    }
    expect(migration).toContain("notify pgrst, 'reload schema'");
    expect(migration).toContain("ACTIVE_MOLLIE_ACCEPTANCE_FIXTURE_REQUIRES_CLEANUP");
    expect(migration).toContain("ORPHAN_MOLLIE_ACCEPTANCE_FIXTURE_REQUIRES_REVIEW");
    expect(migration.indexOf("ACTIVE_MOLLIE_ACCEPTANCE_FIXTURE_REQUIRES_CLEANUP"))
      .toBeLessThan(migration.indexOf("drop function if exists"));
    expect(migration).not.toMatch(/\bcascade\b/i);
  });

  it("does not serialize empty optional provider values into runtime", () => {
    const source = readFileSync(configureRuntime, "utf8");
    expect(source).toContain('].filter(([, value]) => value)');
    expect(source).not.toMatch(/\n\s*MOLLIE_API_KEY:\s*mollieKey/);
    expect(source).not.toMatch(/\n\s*SENDGRID_FROM_EMAIL:\s*fromEmail/);
  });

  it("passes runtime secrets through raw Compose env files without interpolation", () => {
    const compose = readFileSync(path.join(repositoryRoot, "deploy/compose.vps.yml"), "utf8");
    const source = readFileSync(configureRuntime, "utf8");
    expect(compose.match(/\bformat:\s*raw\b/g)).toHaveLength(2);
    expect(source).toContain('`${name}=${String(value ?? "")}`');
    expect(source).not.toContain("function quote(value)");
  });

  it("requires a secret independent heartbeat target in production", () => {
    const environment = runtimeEnvironment("production");
    delete environment.OPERATIONS_HEARTBEAT_URL;
    const result = spawnSync(process.execPath, [configureRuntime, "validate"], { env: environment, encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("OPERATIONS_HEARTBEAT_URL");
  });

  it("requires a canonical importstaging key only when dynamic import is enabled", () => {
    const enabled = {
      ...runtimeEnvironment("staging"),
      DYNAMIC_IMPORT_ENABLED: "true",
      IMPORT_STAGING_ENCRYPTION_KEY: Buffer.alloc(32, 9).toString("base64url"),
    };
    expect(() => execFileSync(process.execPath, [configureRuntime, "validate"], {
      env: enabled,
      stdio: "pipe",
    })).not.toThrow();
    const missing = spawnSync(process.execPath, [configureRuntime, "validate"], {
      env: { ...enabled, IMPORT_STAGING_ENCRYPTION_KEY: "" },
      encoding: "utf8",
    });
    expect(missing.status).toBe(1);
    expect(missing.stderr).toContain("IMPORT_STAGING_ENCRYPTION_KEY");
  });

  it("requires a canonical QR keyring and paired previous key", () => {
    const current = runtimeEnvironment("staging");
    const invalidCurrent = spawnSync(
      process.execPath,
      [configureRuntime, "validate"],
      {
        env: { ...current, QR_TOKEN_PEPPER: "q".repeat(43) },
        encoding: "utf8",
      },
    );
    expect(invalidCurrent.status).toBe(1);
    expect(invalidCurrent.stderr).toContain("QR_TOKEN_PEPPER");

    const rotating = {
      ...current,
      QR_TOKEN_PEPPER: Buffer.alloc(32, 10).toString("base64url"),
      QR_TOKEN_PEPPER_VERSION: "2",
      QR_TOKEN_PREVIOUS_PEPPER:
        Buffer.alloc(32, 8).toString("base64url"),
      QR_TOKEN_PREVIOUS_PEPPER_VERSION: "1",
    };
    expect(() => execFileSync(
      process.execPath,
      [configureRuntime, "validate"],
      { env: rotating, stdio: "pipe" },
    )).not.toThrow();

    const unpaired = spawnSync(
      process.execPath,
      [configureRuntime, "validate"],
      {
        env: { ...rotating, QR_TOKEN_PREVIOUS_PEPPER_VERSION: "" },
        encoding: "utf8",
      },
    );
    expect(unpaired.status).toBe(1);
    expect(unpaired.stderr).toContain("QR_TOKEN_PREVIOUS_PEPPER_VERSION");
  });

  it("accepts only a P-256 SendGrid webhook verification key", () => {
    const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const enabledEmail = {
      ...runtimeEnvironment("staging"),
      EMAIL_ENABLED: "true",
      SENDGRID_API_KEY: "SG.test-key",
      SENDGRID_API_KEY_FINGERPRINT: createHash("sha256")
        .update("SG.test-key")
        .digest("hex"),
      SENDGRID_API_BASE_URL: "https://api.eu.sendgrid.com",
      SENDGRID_FROM_NAME: "Kledingcommissie Duindorp SV",
      SENDGRID_FROM_EMAIL: "kleding@duindorpsv.nl",
      SENDGRID_REPLY_TO_EMAIL: "kleding@duindorpsv.nl",
      SENDGRID_SMOKE_RECIPIENT: "testinbox@example.invalid",
      SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: publicKey.export({ type: "spki", format: "der" }).toString("base64"),
    };
    expect(() => execFileSync(process.execPath, [configureRuntime, "validate"], { env: enabledEmail, stdio: "pipe" })).not.toThrow();
    const invalid = spawnSync(process.execPath, [configureRuntime, "validate"], {
      env: { ...enabledEmail, SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "not-a-public-key" },
      encoding: "utf8",
    });
    expect(invalid.status).toBe(1);
    expect(invalid.stderr).toContain("SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY");
  });

  it("uses the existing smoke inbox for temporary SMTP staging deploys", () => {
    const env = {
      ...runtimeEnvironment("staging"),
      EMAIL_ENABLED: "true",
      EMAIL_PROVIDER: "smtp",
      SMTP_HOST: "mail.voetbalassist.nl",
      SMTP_PORT: "587",
      SMTP_SECURE: "false",
      SMTP_USERNAME: "smtp-user@example.invalid",
      SMTP_PASSWORD: "smtp-password",
      SMTP_FROM_NAME: "Kledingcommissie Duindorp SV",
      SMTP_FROM_EMAIL: "kleding@duindorpsv.nl",
      SMTP_REPLY_TO_EMAIL: "kleding@duindorpsv.nl",
      EMAIL_SMOKE_RECIPIENT: "",
      SENDGRID_SMOKE_RECIPIENT: "testinbox@example.invalid",
    };
    expect(() => execFileSync(process.execPath, [configureRuntime, "validate"], {
      env,
      stdio: "pipe",
    })).not.toThrow();
    const configureRuntimeSource = readFileSync(configureRuntime, "utf8");
    expect(configureRuntimeSource)
      .toContain('const emailSmokeRecipient = optional("EMAIL_SMOKE_RECIPIENT") || smokeRecipient;');
    expect(configureRuntimeSource)
      .toContain('["EMAIL_SMOKE_RECIPIENT", emailSmokeRecipient]');
  });
});

describe("fail-closed release chain", () => {
  const workflowsDirectory = path.join(repositoryRoot, ".github/workflows");
  const workflow = (name: string) => readFileSync(path.join(workflowsDirectory, name), "utf8");

  it("pins every third-party workflow action to a full commit SHA", () => {
    const names = readdirSync(workflowsDirectory)
      .filter((name) => name.endsWith(".yml"));
    for (const name of names) {
      const references = [...workflow(name).matchAll(/uses:\s+[^@\s]+@([^\s#]+)/gu)];
      for (const reference of references) expect(reference[1]).toMatch(/^[a-f0-9]{40}$/u);
    }
  });

  it("deploys only after canonical full CI and attests a scanned immutable image", () => {
    const deploy = workflow("deploy.yml");
    const trivyIgnore = readFileSync(
      path.join(repositoryRoot, "deploy/trivy-release-ignore.yaml"),
      "utf8",
    );
    expect(deploy).toContain("node scripts/deploy/wait-for-ci.mjs");
    expect(deploy).toContain("Reject high or critical runtime vulnerabilities");
    expect(deploy).toContain("ignore-unfixed: false");
    expect(deploy).toContain("trivyignores: deploy/trivy-release-ignore.yaml");
    expect(trivyIgnore.match(/CVE-[0-9-]+/gu)).toEqual(["CVE-2026-14456"]);
    expect(trivyIgnore).toContain(
      "pkg:deb/debian/libssl3t64@3.5.6-1~deb13u2?arch=amd64&distro=debian-13.6",
    );
    expect(trivyIgnore).toContain("expired_at: 2026-09-01");
    expect(deploy).toContain("format: spdx-json");
    expect(deploy).toContain("cosign sign-blob .release/SHA256SUMS");
    expect(deploy).toContain("--bundle .release/SHA256SUMS.sigstore.json");
    expect(deploy.match(/cosign verify-blob \.release\/SHA256SUMS/gu)).toHaveLength(2);
    expect(deploy).toContain("sha256sum duindorpteneu-app.tar.gz RELEASE_MANIFEST sbom.spdx.json");
    expect(deploy).not.toContain("actions/attest-build-provenance@");
    expect(deploy).not.toContain("actions/attest-sbom@");
    expect(deploy).toContain("staging-attestation-deploy-${{ github.run_id }}");
    expect(deploy).toContain("retention-days: 30");
  });

  it("never runs dependency lifecycle scripts in a trusted workflow checkout", () => {
    for (const name of [
      "ci.yml",
      "deploy.yml",
      "promote-production.yml",
      "staging-core-acceptance.yml",
      "staging-mollie-acceptance.yml",
      "staging-phase-b-acceptance.yml",
      "staging-provider-smoke.yml",
    ]) {
      const source = workflow(name);
      for (const install of source.matchAll(
        /pnpm install --frozen-lockfile[^\n]*/gu,
      )) {
        expect(install[0]).toContain("--ignore-scripts");
      }
    }
    for (const name of [
      "ci.yml",
      "deploy.yml",
      "promote-production.yml",
      "staging-phase-b-acceptance.yml",
    ]) {
      expect(workflow(name)).toContain(
        "bash scripts/deploy/install-supabase-cli.sh",
      );
    }
    expect(workflow("promote-production.yml")).toContain(
      "bash scripts/deploy/install-github-cli.sh",
    );
  });

  it("uses temporary SMTP by default on staging while production stays explicit SendGrid", () => {
    const staging = workflow("deploy.yml");
    const production = workflow("promote-production.yml");
    expect(staging).toContain("EMAIL_PROVIDER: ${{ vars.EMAIL_PROVIDER || 'smtp' }}");
    expect(staging).toContain("SMTP_FROM_NAME: ${{ vars.SMTP_FROM_NAME || vars.SENDGRID_FROM_NAME || 'Kledingcommissie Duindorp SV' }}");
    expect(staging).toContain("SMTP_FROM_EMAIL: ${{ vars.SMTP_FROM_EMAIL || vars.SENDGRID_FROM_EMAIL || 'kleding@duindorpsv.nl' }}");
    expect(staging).toContain("SMTP_REPLY_TO_EMAIL: ${{ vars.SMTP_REPLY_TO_EMAIL || vars.SENDGRID_REPLY_TO_EMAIL || 'kleding@duindorpsv.nl' }}");
    expect(production).toContain("EMAIL_PROVIDER: ${{ vars.EMAIL_PROVIDER || 'sendgrid' }}");
    expect(production).toContain("EMAIL_BULK_ENABLED: ${{ vars.EMAIL_BULK_ENABLED || 'false' }}");
  });

  it("rerunt repository gates niet opnieuw in deploy-preflight na exacte main-CI", () => {
    const staging = workflow("deploy.yml");
    const preflight = staging.slice(
      staging.indexOf("preflight:"),
      staging.indexOf("build-release:"),
    );
    expect(preflight).toContain("Require successful full CI on exact release SHA");
    expect(preflight).not.toContain("Install locked dependencies");
    expect(preflight).not.toContain("Run repository gates");
    expect(preflight).not.toContain("pnpm lint");
    expect(preflight).not.toContain("pnpm build");
  });

  it("serializes every staging mutation or acceptance on the deployment lock", () => {
    for (const name of [
      "adopt-legacy-production.yml",
      "deploy.yml",
      "promote-production.yml",
      "staging-core-acceptance.yml",
      "staging-domain-cleanup.yml",
      "staging-mollie-acceptance.yml",
      "staging-phase-b-acceptance.yml",
      "staging-operations.yml",
      "staging-provider-smoke.yml",
      "staging-restore-drill.yml",
      "staging-rollback-drill.yml",
      "staging-sendgrid-webhook-configure.yml",
    ]) expect(workflow(name)).toContain("group: deploy-duindorpteneu-staging");
  });

  it("binds SendGrid delivery evidence after final health and gates branding races", () => {
    const provider = workflow("staging-provider-smoke.yml");
    const harness = provider.indexOf(
      "Verify app delivery and signed recipient-server acceptance",
    );
    const finalHealth = provider.indexOf(
      "Verify final internal health after provider evidence",
    );
    const fixtureCleanup = provider.indexOf(
      "Always deactivate and remove SendGrid acceptance auth fixture",
    );
    const result = provider.indexOf(
      "Create exact SendGrid provider result",
    );
    expect(harness).toBeGreaterThan(-1);
    expect(fixtureCleanup).toBeGreaterThan(harness);
    expect(finalHealth).toBeGreaterThan(fixtureCleanup);
    expect(finalHealth).toBeGreaterThan(harness);
    expect(result).toBeGreaterThan(finalHealth);
    expect(provider).toContain(
      "sendgrid-acceptance-evidence.mjs finalize",
    );
    expect(provider).toContain(
      "${{ runner.temp }}/sendgrid-acceptance-evidence.json",
    );
    expect(provider).toContain(
      '"${ARTIFACT_DIGEST}" "${EVIDENCE_PATH}"',
    );
    expect(provider).not.toContain(
      "node scripts/staging/require-database-tls.mjs",
    );
    expect(provider).toContain(
      "SUPABASE_SERVICE_ROLE_KEY: ${{ secrets.SUPABASE_SERVICE_ROLE_KEY }}",
    );
    expect(provider).toContain('CLEANUP_ONLY: "1"');
    expect(provider).toMatch(
      /- name: Always deactivate and remove SendGrid acceptance auth fixture\n\s+if: always\(\)/u,
    );
    expect(provider).toContain(
      "timeout --signal=TERM --kill-after=15s 8m",
    );
    expect(provider).toContain(
      "timeout --signal=TERM --kill-after=15s 3m",
    );
    expect(provider.match(
      /SUPABASE_DB_URL: \$\{\{ secrets\.SUPABASE_DB_URL \}\}/gu,
    )).toHaveLength(2);
    expect(provider).not.toContain("E2E_ADMIN_EMAIL");
    expect(provider).not.toContain("E2E_ADMIN_PASSWORD");
    expect(provider).not.toContain("E2E_ADMIN_TOTP_SECRET");
    expect(workflow("ci.yml")).toContain(
      "pnpm test:db:branding-concurrency",
    );
    expect(workflow("staging-phase-b-acceptance.yml")).toContain(
      "test:db:branding-concurrency",
    );
  });

  it("requires every exact-artifact acceptance and human UAT before production", () => {
    const promotion = workflow("promote-production.yml");
    for (const input of [
      "core_run_id:",
      "phase_b_run_id:",
      "mollie_run_id:",
      "sendgrid_run_id:",
      "restore_run_id:",
      "rollback_run_id:",
      "operations_run_id:",
      '[[ "${PROMOTION_CONFIRMATION}" == "HUMAN-UAT-PASSED+PROMOTE-PRODUCTION" ]]',
      "node scripts/deploy/verify-promotion-evidence.mjs",
    ]) expect(promotion).toContain(input);
    expect(promotion.match(/verify-promotion-evidence\.mjs/gu)).toHaveLength(2);
    expect(promotion.match(/cosign verify-blob \.release\/SHA256SUMS/gu)).toHaveLength(2);
    expect(promotion).not.toContain("gh attestation verify");
  });

  it("validates every manual staging release on trusted main before environment secrets", () => {
    const trusted = workflow("_trusted-staging-preflight.yml");
    expect(trusted).toContain("ref: refs/heads/main");
    expect(trusted).toContain('[[ "$(git rev-parse HEAD)" == "${REQUESTED_RELEASE_SHA}" ]]');
    expect(trusted).toContain("node scripts/deploy/verify-staging-deploy.mjs");
    expect(trusted).not.toMatch(/\bsecrets\./u);
    expect(trusted).not.toContain("environment: staging");
    for (const name of [
      "adopt-legacy-production.yml",
      "staging-core-acceptance.yml",
      "staging-domain-cleanup.yml",
      "staging-mollie-acceptance.yml",
      "staging-phase-b-acceptance.yml",
      "staging-operations.yml",
      "staging-provider-smoke.yml",
      "staging-restore-drill.yml",
      "staging-rollback-drill.yml",
      "staging-sendgrid-webhook-configure.yml",
    ]) {
      const source = workflow(name);
      expect(source).toContain("uses: ./.github/workflows/_trusted-staging-preflight.yml");
      expect(source).toContain("needs: preflight");
    }
  });

  it("rechecks origin/main immediately on both staging and production runners", () => {
    const deployScript = readFileSync(path.join(repositoryRoot, "scripts/deploy-vps.sh"), "utf8");
    const productionConditional = deployScript.indexOf('if [[ "$environment" == production ]]');
    const mainFetch = deployScript.indexOf("git fetch origin main --no-tags");
    expect(mainFetch).toBeGreaterThan(productionConditional);
    expect(deployScript.slice(productionConditional, mainFetch)).toContain(
      "release-manifest.mjs compare",
    );
    expect(deployScript.slice(mainFetch)).toContain(
      '[[ "$current_main" == "$RELEASE_SHA" && "${GITHUB_SHA:-}" == "$RELEASE_SHA" ]]',
    );
  });

  it("keeps the one-time legacy rollback contract evidence-bound", () => {
    const deployScript = readFileSync(
      path.join(repositoryRoot, "scripts/deploy-vps.sh"),
      "utf8",
    );
    expect(deployScript).toContain(
      "a79c8d843d75e90810ccceb228538c6368d2198b",
    );
    expect(deployScript).toContain(
      "legacy-adoption-evidence.mjs verify-provenance",
    );
    expect(deployScript).toContain("check-legacy-http.mjs");
    expect(deployScript).toContain("legacy-v1-exact-four-fields");
    expect(deployScript).toContain(
      "node scripts/deploy/normalize-legacy-runtime.mjs",
    );
    expect(deployScript).toContain("stop_scheduler_for_legacy");
    expect(deployScript).toContain(
      '-f "$compose_file" up -d --no-build app',
    );
    expect(deployScript).not.toContain("ALLOW_LEGACY_HEALTH");
  });

  it("never starts the schema-incompatible pre-Phase-B staging release", () => {
    const deployScript = readFileSync(
      path.join(repositoryRoot, "scripts/deploy-vps.sh"),
      "utf8",
    );
    expect(deployScript).toContain(
      'incompatible_staging_rollback_revision="a846c059bce3d7e794504acca57a4771dfdb536d"',
    );
    expect(deployScript).toContain("previous_app_compatible=false");
    expect(deployScript).toContain(
      "De schema-incompatibele oude stagingapp draait nog",
    );
    expect(deployScript).toContain(
      "de schema-incompatibele oude stagingapp wordt niet gestart",
    );
    expect(deployScript).toContain(
      '-f "$compose_file" stop app scheduler',
    );
    expect(deployScript).toContain(
      '&& "$previous_app_compatible" == true',
    );
  });

  it("authenticates and verifies the durable production backup redownload", () => {
    const promotion = workflow("promote-production.yml");
    const start = promotion.indexOf(
      "Bind durable production backup identity to this promotion",
    );
    const end = promotion.indexOf(
      "Verify staged artifact and deploy production",
    );
    const step = promotion.slice(start, end);
    expect(step).toContain("GH_TOKEN: ${{ github.token }}");
    expect(step).toContain("command -v gh");
    expect(step).toContain("command -v unzip");
    expect(step).toContain("gh api");
    expect(step).toContain("sha256sum");
  });
});

describe("immutable release manifest", () => {
  it("compares the OCI, config and transported artifact digests", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "duindorp-release-"));
    temporaryDirectories.push(directory);
    const build = path.join(directory, "build.json");
    const staging = path.join(directory, "staging.json");
    const tag = `duindorpteneu-app:${releaseSha}`;
    const imageDigest = `sha256:${"1".repeat(64)}`;
    const configDigest = `sha256:${"2".repeat(64)}`;
    const artifactDigest = `sha256:${"3".repeat(64)}`;
    const create = (target: string, environment: string) => execFileSync(process.execPath, [
      releaseManifest,
      "create",
      target,
      environment,
      releaseSha,
      tag,
      imageDigest,
      configDigest,
      artifactDigest,
    ]);
    create(build, "build");
    create(staging, "staging");
    expect(() => execFileSync(process.execPath, [releaseManifest, "compare", build, staging])).not.toThrow();
    expect(() => execFileSync(process.execPath, [releaseManifest, "verify", build, releaseSha, imageDigest, configDigest, artifactDigest])).not.toThrow();
    expect(execFileSync(process.execPath, [releaseManifest, "fields", build], { encoding: "utf8" }))
      .toBe(`${imageDigest} ${configDigest} ${artifactDigest}\n`);
  });
});
