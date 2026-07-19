import { execFileSync, spawnSync } from "node:child_process";
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
    const layout = readFileSync(path.join(repositoryRoot, "src/app/layout.tsx"), "utf8");
    expect(dockerfile).not.toMatch(/\b(?:ARG|ENV)\s+NEXT_PUBLIC_/);
    expect(layout).toContain("globalThis.__DUINDORP_RUNTIME_CONFIG__");
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
  });
});
