import { execFileSync, spawnSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
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
  const host = staging ? "staging-duindorp.dgwebservices.nl" : "duindorp.dgwebservices.nl";
  return {
    ...process.env,
    DEPLOY_ENVIRONMENT: environment,
    RELEASE_SHA: releaseSha,
    RUNTIME_DIRECTORY: `/srv/apps/duindorpteneu/${environment}`,
    COMPOSE_PROJECT_NAME: `duindorpteneu-${environment}`,
    APP_HOST: host,
    APP_BIND_PORT: staging ? "14000" : "24000",
    NEXT_PUBLIC_APP_URL: `https://${host}`,
    SUPABASE_PROJECT_REF: ref,
    NEXT_PUBLIC_SUPABASE_URL: `https://${ref}.supabase.co`,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt("anon", ref),
    SUPABASE_SERVICE_ROLE_KEY: jwt("service_role", ref),
    SUPABASE_DB_URL: `postgresql://postgres:password@db.${ref}.supabase.co:5432/postgres?sslmode=require`,
    NEXT_SERVER_ACTIONS_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64"),
    PARENT_TOKEN_PEPPER: "p".repeat(32),
    CRON_SECRET: "c".repeat(32),
    ...(staging ? {} : { OPERATIONS_HEARTBEAT_URL: "https://monitor.example/ping-secret" }),
    MOLLIE_ENABLED: "false",
    EMAIL_ENABLED: "false",
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

  it("keeps public browser configuration runtime-injected", () => {
    const dockerfile = readFileSync(path.join(repositoryRoot, "Dockerfile"), "utf8");
    const dockerignore = readFileSync(path.join(repositoryRoot, ".dockerignore"), "utf8");
    const layout = readFileSync(path.join(repositoryRoot, "src/app/layout.tsx"), "utf8");
    expect(dockerfile).not.toMatch(/\b(?:ARG|ENV)\s+NEXT_PUBLIC_/);
    expect(dockerignore.split(/\r?\n/)).toContain(".release");
    expect(layout).toContain("globalThis.__DUINDORP_RUNTIME_CONFIG__");
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
    const refreshMigration = readFileSync(
      path.join(repositoryRoot, "supabase/migrations/20260720142000_refresh_postgrest_settings_contract.sql"),
      "utf8",
    );
    const deployScript = readFileSync(path.join(repositoryRoot, "scripts/deploy-vps.sh"), "utf8");
    const contractScript = readFileSync(path.join(repositoryRoot, "scripts/deploy/check-postgrest-rpcs.mjs"), "utf8");
    expect(refreshMigration).toContain("notify pgrst, 'reload schema'");
    expect(refreshMigration).not.toMatch(/\b(?:insert|update|delete|truncate)\b/i);
    expect(refreshMigration).toContain("get_settings_rpc_contract_version");
    expect(refreshMigration).toContain("'get_settings_workspace_v2'");
    expect(refreshMigration).toContain("'update_settings_v2'");
    expect(refreshMigration).toContain("'create_season_v2'");
    expect(refreshMigration).toContain("grant execute on function app.get_settings_rpc_contract_version() to service_role");
    expect(contractScript).toContain("/rest/v1/rpc/get_settings_rpc_contract_version");
    expect(contractScript).not.toContain("get_settings_workspace_v2");
    expect(deployScript.indexOf("node scripts/deploy/check-postgrest-rpcs.mjs"))
      .toBeGreaterThan(deployScript.indexOf('pnpm exec supabase db push --db-url "$SUPABASE_DB_URL" --yes'));
  });

  it("does not serialize empty optional provider values into runtime", () => {
    const source = readFileSync(configureRuntime, "utf8");
    expect(source).toContain('].filter(([, value]) => value)');
    expect(source).not.toMatch(/\n\s*MOLLIE_API_KEY:\s*mollieKey/);
    expect(source).not.toMatch(/\n\s*SENDGRID_FROM_EMAIL:\s*fromEmail/);
  });

  it("requires a secret independent heartbeat target in production", () => {
    const environment = runtimeEnvironment("production");
    delete environment.OPERATIONS_HEARTBEAT_URL;
    const result = spawnSync(process.execPath, [configureRuntime, "validate"], { env: environment, encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("OPERATIONS_HEARTBEAT_URL");
  });

  it("accepts only a P-256 SendGrid webhook verification key", () => {
    const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const enabledEmail = {
      ...runtimeEnvironment("staging"),
      EMAIL_ENABLED: "true",
      SENDGRID_API_KEY: "SG.test-key",
      SENDGRID_API_BASE_URL: "https://api.eu.sendgrid.com",
      SENDGRID_FROM_EMAIL: "danny.goldenbelt@duindorpsv.nl",
      SENDGRID_REPLY_TO_EMAIL: "danny.goldenbelt@duindorpsv.nl",
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
