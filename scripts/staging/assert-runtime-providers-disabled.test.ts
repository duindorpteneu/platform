import { describe, expect, it } from "vitest";
// @ts-expect-error The runtime assertion intentionally uses plain Node.js ESM.
import { assertRuntimeProvidersDisabled } from "./assert-runtime-providers-disabled.mjs";

const disabledRuntime = [
  "NODE_ENV=production",
  "DYNAMIC_IMPORT_ENABLED=false",
  "EMAIL_ENABLED=false",
  "MOLLIE_ENABLED=false",
  "SENDGRID_API_KEY=not-inspected",
  "",
].join("\n");

describe("staging runtime provider shutdown", () => {
  it("accepts only three explicit disabled flags", () => {
    expect(assertRuntimeProvidersDisabled(disabledRuntime)).toBe(true);
  });

  it.each([
    disabledRuntime.replace("EMAIL_ENABLED=false", "EMAIL_ENABLED=true"),
    disabledRuntime.replace("MOLLIE_ENABLED=false", ""),
    `${disabledRuntime}EMAIL_ENABLED=false\n`,
    disabledRuntime.replace("DYNAMIC_IMPORT_ENABLED=false", "DYNAMIC_IMPORT_ENABLED=\"false\""),
  ])("rejects enabled, absent, duplicate or quoted provider flags", (runtime) => {
    expect(() => assertRuntimeProvidersDisabled(runtime)).toThrow();
  });

  it("does not interpret shell syntax or malformed records", () => {
    expect(() => assertRuntimeProvidersDisabled(
      `${disabledRuntime}UNSAFE=$(false)\n`,
    )).toBeDefined();
    expect(() => assertRuntimeProvidersDisabled(
      `${disabledRuntime}not-an-assignment\n`,
    )).toThrow("STAGING_RUNTIME_ENV_INVALID");
  });
});
