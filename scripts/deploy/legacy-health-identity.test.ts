import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js deployment helper.
import * as legacyHealthIdentity from "./legacy-health-identity.mjs";
const {
  assertLegacyHealthIdentity,
  LEGACY_PRODUCTION_SHA,
} = legacyHealthIdentity;

const health = {
  status: "ok",
  service: "duindorpteneu",
  environment: "production",
  revision: LEGACY_PRODUCTION_SHA,
};

describe("strict one-time legacy health identity", () => {
  it("accepts only the exact known production release", () => {
    expect(assertLegacyHealthIdentity(
      health,
      "production",
      LEGACY_PRODUCTION_SHA,
    )).toEqual(health);
  });

  it.each([
    { artifactDigest: `sha256:${"a".repeat(64)}` },
    { revision: "b".repeat(40) },
    { environment: "staging" },
    { service: "other" },
    { secret: "unexpected" },
  ])("rejects drift and extra metadata", (patch) => {
    expect(() => assertLegacyHealthIdentity(
      { ...health, ...patch },
      "production",
      LEGACY_PRODUCTION_SHA,
    )).toThrow();
  });
});
