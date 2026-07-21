import { describe, expect, it } from "vitest";
import { targetFromEnvironment } from "./core-browser-acceptance.mjs";

const valid = {
  STAGING_BASE_URL: "https://staging-duindorp.dgwebservices.nl",
  SUPABASE_PROJECT_REF: "dxbdjtbyghsovlrdcwcr",
  RELEASE_SHA: "a".repeat(40),
  CONFIRMATION: "STAGING-CORE",
};

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
});
