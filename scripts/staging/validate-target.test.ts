import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import * as targetContract from "./validate-target.mjs";

const {
  CLEANUP_APPLY_CONFIRMATION,
  CLEANUP_DRY_RUN_CONFIRMATION,
  PRODUCTION_PROJECT_REF,
  RESTORE_CONFIRMATION,
  STAGING_ORIGIN,
  STAGING_PROJECT_REF,
  validateStagingCleanupTarget,
  validateStagingRestoreTarget,
} = targetContract;

const projectRef = "abcdefghijklmnopqrst";
const releaseSha = "a".repeat(40);
const postgresImage = "public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453";

function values(overrides: Record<string, string> = {}) {
  return {
    TARGET_ENVIRONMENT: "staging",
    STAGING_APP_URL: STAGING_ORIGIN,
    SUPABASE_PROJECT_REF: projectRef,
    SUPABASE_DB_URL: `postgresql://postgres:secret@db.${projectRef}.supabase.co:5432/postgres?sslmode=require`,
    RELEASE_SHA: releaseSha,
    CONFIRM_TARGET: RESTORE_CONFIRMATION,
    ...overrides,
  };
}

describe("validateStagingRestoreTarget", () => {
  it("pint het workflow- en restore-image op exact dezelfde digest", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/staging-restore-drill.yml", import.meta.url), "utf8");
    const restoreScript = readFileSync(new URL("./restore-drill.sh", import.meta.url), "utf8");

    expect(workflow).toContain(`POSTGRES_IMAGE: ${postgresImage}`);
    expect(restoreScript).toContain(`expected_postgres_image="${postgresImage}"`);
    expect(workflow).not.toContain("POSTGRES_IMAGE: public.ecr.aws/supabase/postgres:17.6.1.143\n");
  });

  it("accepteert alleen het vaste stagingdoel met overeenkomende directe database", () => {
    expect(validateStagingRestoreTarget(values())).toMatchObject({
      environment: "staging",
      appUrl: STAGING_ORIGIN,
      projectRef,
      releaseSha,
    });
  });

  it("accepteert een Supabase-sessionpooler als de username de projectref draagt", () => {
    expect(validateStagingRestoreTarget(values({
      SUPABASE_DB_URL: `postgresql://postgres.${projectRef}:secret@aws-0-eu-central-1.pooler.supabase.com:5432/postgres`,
    })).projectRef).toBe(projectRef);
  });

  it.each([
    ["TARGET_ENVIRONMENT", "production"],
    ["STAGING_APP_URL", "https://duindorp.dgwebservices.nl"],
    ["SUPABASE_PROJECT_REF", "zyxwvutsrqponmlkjihg"],
    ["SUPABASE_DB_URL", "postgresql://postgres:secret@db.zyxwvutsrqponmlkjihg.supabase.co/postgres"],
    ["SUPABASE_DB_URL", `postgresql://postgres:secret@db.${projectRef}.supabase.co/postgres?sslmode=disable`],
    ["RELEASE_SHA", "abc123"],
    ["CONFIRM_TARGET", "staging"],
  ])("weigert een onveilige waarde voor %s", (name, value) => {
    expect(() => validateStagingRestoreTarget(values({ [name]: value }))).toThrow();
  });
});

describe("validateStagingCleanupTarget", () => {
  function cleanupValues(mode: "dry-run" | "apply") {
    return values({
      CLEANUP_MODE: mode,
      SUPABASE_PROJECT_REF: STAGING_PROJECT_REF,
      SUPABASE_DB_URL: `postgresql://postgres:secret@db.${STAGING_PROJECT_REF}.supabase.co:5432/postgres?sslmode=require`,
      CONFIRM_TARGET: mode === "apply"
        ? CLEANUP_APPLY_CONFIRMATION
        : CLEANUP_DRY_RUN_CONFIRMATION,
    });
  }

  it.each(["dry-run", "apply"] as const)("accepteert %s uitsluitend op het vaste stagingproject", (mode) => {
    expect(validateStagingCleanupTarget(cleanupValues(mode))).toMatchObject({
      mode,
      projectRef: STAGING_PROJECT_REF,
      appUrl: STAGING_ORIGIN,
    });
  });

  it("weigert production ook wanneer URL en database onderling overeenkomen", () => {
    expect(() => validateStagingCleanupTarget({
      ...cleanupValues("apply"),
      SUPABASE_PROJECT_REF: PRODUCTION_PROJECT_REF,
      SUPABASE_DB_URL: `postgresql://postgres:secret@db.${PRODUCTION_PROJECT_REF}.supabase.co:5432/postgres?sslmode=require`,
    })).toThrow("productionproject");
  });

  it.each([
    { CLEANUP_MODE: "apply", CONFIRM_TARGET: CLEANUP_DRY_RUN_CONFIRMATION },
    { CLEANUP_MODE: "dry-run", CONFIRM_TARGET: CLEANUP_APPLY_CONFIRMATION },
    { CLEANUP_MODE: "apply", SUPABASE_PROJECT_REF: projectRef, SUPABASE_DB_URL: `postgresql://postgres:secret@db.${projectRef}.supabase.co:5432/postgres?sslmode=require` },
    { CLEANUP_MODE: "apply", SUPABASE_DB_URL: `postgresql://postgres:secret@db.${STAGING_PROJECT_REF}.supabase.co:5432/postgres` },
    { CLEANUP_MODE: "apply", SUPABASE_DB_URL: `postgresql://wrong:secret@db.${STAGING_PROJECT_REF}.supabase.co:5432/postgres?sslmode=require` },
    { CLEANUP_MODE: "erase", CONFIRM_TARGET: CLEANUP_APPLY_CONFIRMATION },
  ])("weigert een cleanupcontract dat niet exact overeenkomt", (override) => {
    expect(() => validateStagingCleanupTarget({
      ...cleanupValues("apply"),
      ...override,
    })).toThrow();
  });
});
