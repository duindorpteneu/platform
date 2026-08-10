import { describe, expect, it } from "vitest";

// @ts-expect-error JavaScript deployment helper without declaration file.
import { assertHealthIdentity } from "./health-identity.mjs";

const revision = "a".repeat(40);
const artifactDigest = `sha256:${"b".repeat(64)}`;
const health = {
  status: "ok",
  service: "duindorpteneu",
  environment: "staging",
  revision,
  artifactDigest,
};

describe("live release identity", () => {
  it("accepts only the exact SHA and artifact digest", () => {
    expect(() => assertHealthIdentity(
      health,
      "staging",
      revision,
      artifactDigest,
    )).not.toThrow();
  });

  it("rejects a different artifact built from the same SHA", () => {
    expect(() => assertHealthIdentity(
      health,
      "staging",
      revision,
      `sha256:${"c".repeat(64)}`,
    )).toThrow("verkeerde release-identiteit");
  });
});
