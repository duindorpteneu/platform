import { describe, expect, it } from "vitest";
import { databaseTargetFromEnvironment, targetFromEnvironment } from "./core-browser-acceptance.mjs";

const valid = {
  STAGING_BASE_URL: "https://staging-duindorp.dgwebservices.nl",
  SUPABASE_PROJECT_REF: "dxbdjtbyghsovlrdcwcr",
  RELEASE_SHA: "a".repeat(40),
  CONFIRMATION: "STAGING-CORE",
};
const STAGING_REF = "dxbdjtbyghsovlrdcwcr";

describe("staging core target", () => {
  it("accepts only the canonical staging identity", () => {
    expect(targetFromEnvironment(valid).projectRef).toBe("dxbdjtbyghsovlrdcwcr");
    expect(() => targetFromEnvironment({ ...valid, STAGING_BASE_URL: "https://duindorp.dgwebservices.nl" })).toThrow("STAGING_TARGET_INVALID");
    expect(() => targetFromEnvironment({ ...valid, SUPABASE_PROJECT_REF: "wobcbufmmputydtzemyu" })).toThrow("STAGING_TARGET_INVALID");
  });

  it("requires an exact release and confirmation", () => {
    expect(() => targetFromEnvironment({ ...valid, RELEASE_SHA: "main" })).toThrow("RELEASE_SHA_INVALID");
    expect(() => targetFromEnvironment({ ...valid, CONFIRMATION: "yes" })).toThrow("CONFIRMATION_INVALID");
  });

  it("accepts only a PostgreSQL URL bound to the staging project", () => {
    expect(databaseTargetFromEnvironment({ SUPABASE_DB_URL: "postgresql://postgres.dxbdjtbyghsovlrdcwcr:secret@pooler.supabase.com:6543/postgres" })).toContain(STAGING_REF);
    expect(() => databaseTargetFromEnvironment({ SUPABASE_DB_URL: "postgresql://postgres.production:secret@pooler.supabase.com:6543/postgres" })).toThrow("STAGING_DATABASE_TARGET_INVALID");
    expect(() => databaseTargetFromEnvironment({ SUPABASE_DB_URL: "https://dxbdjtbyghsovlrdcwcr.supabase.co" })).toThrow("STAGING_DATABASE_TARGET_INVALID");
  });
});
