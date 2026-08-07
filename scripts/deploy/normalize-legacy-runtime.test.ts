import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js deployment helper.
import * as legacyRuntime from "./normalize-legacy-runtime.mjs";
const {
  buildLegacyRuntime,
  parseLegacyRuntime,
} = legacyRuntime;

const identity = {
  environment: "production",
  releaseSha: "a79c8d843d75e90810ccceb228538c6368d2198b",
  artifactDigest: `sha256:${"a".repeat(64)}`,
};

describe("legacy runtime normalisatie", () => {
  it("decodes the historical quoted writer without eval or interpolation", () => {
    const output = buildLegacyRuntime([
      'APP_ENVIRONMENT="production"',
      'APP_BASE_URL="https://duindorp.dgwebservices.nl"',
      'PARENT_TOKEN_PEPPER="backslash\\\\and\\"quote"',
      'EMAIL_ENABLED="true"',
      'MOLLIE_ENABLED="true"',
      "",
    ].join("\n"), identity);
    expect(output).toContain("APP_ENVIRONMENT=production\n");
    expect(output).toContain(
      'PARENT_TOKEN_PEPPER=backslash\\and"quote\n',
    );
    expect(output).toContain("EMAIL_ENABLED=false\n");
    expect(output).toContain("MOLLIE_ENABLED=false\n");
    expect(output).toContain("DYNAMIC_IMPORT_ENABLED=false\n");
    expect(output).toContain(
      `RELEASE_ARTIFACT_DIGEST=${identity.artifactDigest}\n`,
    );
    expect(output).not.toContain('APP_ENVIRONMENT="production"');
  });

  it("keeps an already raw runtime raw and forces the staging identity", () => {
    const output = buildLegacyRuntime(
      "APP_ENVIRONMENT=production\nTOKEN=$literal\n",
      { ...identity, environment: "staging" },
    );
    expect(output).toContain("APP_ENVIRONMENT=staging\n");
    expect(output).toContain("TOKEN=$literal\n");
  });

  it.each([
    'A="unterminated',
    'A="bad\\nescape"',
    "A=one\nA=two\n",
    "lower=value\n",
    "NO_SEPARATOR\n",
    "",
  ])("rejects malformed runtime input", (source) => {
    expect(() => parseLegacyRuntime(source)).toThrow();
  });

  it("rejects invalid target identities", () => {
    expect(() => buildLegacyRuntime("A=value\n", {
      ...identity,
      artifactDigest: "sha256:short",
    })).toThrow("doelidentiteit");
  });
});
