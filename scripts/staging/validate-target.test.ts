import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { RESTORE_CONFIRMATION, STAGING_ORIGIN, validateStagingRestoreTarget } from "./validate-target.mjs";

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
