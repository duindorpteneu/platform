import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createHmac } from "node:crypto";
import {
  createNeutralParentChallengeContext,
  deriveParentCode,
  deriveParentDirectCredential,
  maskParentEmail,
  normalizeParentEmail,
  openParentChallengeContext,
  parentSessionExpiresAt,
  PARENT_SESSION_COOKIE_MAX_AGE_SECONDS,
  PARENT_SESSION_DATABASE_MAX_AGE_SECONDS,
  parentCodeInputSchema,
  parentCodeSchema,
  parentEmailSchema,
  sealParentChallengeContext,
  stagingAcceptanceChallengeId,
  stagingAcceptanceSessionCorrelation,
  verifyParentDirectCredential,
} from "@/server/auth/parent";

const challengeId = "11111111-1111-4111-8111-111111111111";

describe("parent authentication boundary", () => {
  beforeEach(() => {
    process.env.PARENT_TOKEN_PEPPER =
      "test-parent-pepper-with-thirty-two-characters";
  });
  afterEach(() => {
    delete process.env.PARENT_TOKEN_PEPPER;
    delete process.env.APP_ENVIRONMENT;
    delete process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED;
  });

  it("normalizes and masks parent email addresses", () => {
    expect(normalizeParentEmail("  OUDER@Example.NL ")).toBe(
      "ouder@example.nl",
    );
    expect(maskParentEmail("L@example.nl")).toBe("l***@example.nl");
    expect(maskParentEmail("LangeNaam@example.nl")).toBe(
      "l********@example.nl",
    );
    expect(parentEmailSchema.safeParse({ email: "ouder@example.nl" }).success)
      .toBe(true);
  });

  it("accepts exactly six numeric digits", () => {
    expect(parentCodeSchema.safeParse({
      email: "ouder@example.nl",
      code: "123456",
    }).success).toBe(true);
    expect(parentCodeSchema.safeParse({
      email: "ouder@example.nl",
      code: "12345",
    }).success).toBe(false);
    expect(parentCodeInputSchema.safeParse({ code: "123456" }).success)
      .toBe(true);
  });

  it("derives stable domain-separated credentials without plaintext storage", () => {
    const code = deriveParentCode(challengeId);
    const credential = deriveParentDirectCredential(challengeId);
    expect(code).toMatch(/^[1-9]\d{5}$/u);
    expect(deriveParentCode(challengeId)).toBe(code);
    expect(credential).toMatch(/^v1\.[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/u);
    expect(credential).not.toContain(code);
    expect(verifyParentDirectCredential(credential)).toBe(challengeId);
    expect(verifyParentDirectCredential(`${credential.slice(0, -1)}x`))
      .toBeNull();
    expect(verifyParentDirectCredential(`v1.${challengeId}.${"A".repeat(43)}`))
      .toBeNull();
  });

  it("seals an opaque expiring challenge context", () => {
    const context = createNeutralParentChallengeContext(
      "OUDER@example.nl",
      1_000,
    );
    const token = sealParentChallengeContext(context);
    expect(token).not.toContain("ouder");
    expect(openParentChallengeContext(token, 2_000)).toEqual({
      ...context,
      email: "ouder@example.nl",
    });
    expect(openParentChallengeContext(token, 10 * 60 * 1_000 + 1_001))
      .toBeNull();
    expect(openParentChallengeContext(`${token}tampered`, 2_000)).toBeNull();
  });

  it("keeps parent session expiry inside the database clock-skew boundary", () => {
    const now = Date.parse("2026-08-21T21:00:00.000Z");
    expect(parentSessionExpiresAt(now)).toBe(
      "2026-09-20T20:55:00.000Z",
    );
    expect(PARENT_SESSION_COOKIE_MAX_AGE_SECONDS).toBe(30 * 24 * 60 * 60);
    expect(PARENT_SESSION_DATABASE_MAX_AGE_SECONDS).toBe(
      PARENT_SESSION_COOKIE_MAX_AGE_SECONDS - 5 * 60,
    );
  });

  it("accepts signed challenge ownership only behind the staging gate", () => {
    const fixtureDigest = "a".repeat(64);
    const proof = createHmac(
      "sha256",
      process.env.PARENT_TOKEN_PEPPER!,
    ).update(
      `parent-login-staging-challenge:v1\0${fixtureDigest}\0${challengeId}`,
      "utf8",
    ).digest("hex");
    const request = new Request("https://tenue.example/login", {
      headers: {
        "x-duindorp-staging-challenge-id": challengeId,
        "x-duindorp-staging-challenge-proof": proof,
        "x-duindorp-staging-fixture-digest": fixtureDigest,
      },
    });
    expect(stagingAcceptanceChallengeId(request)).toBeNull();
    process.env.APP_ENVIRONMENT = "staging";
    process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED = "true";
    expect(stagingAcceptanceChallengeId(request)).toBe(challengeId);
    expect(stagingAcceptanceChallengeId(new Request(request, {
      headers: { ...Object.fromEntries(request.headers),
        "x-duindorp-staging-challenge-proof": "b".repeat(64) },
    }))).toBeNull();
    process.env.APP_ENVIRONMENT = "production";
    expect(stagingAcceptanceChallengeId(request)).toBeNull();
  });

  it("derives a signed staging-only session correlation", () => {
    const fixtureDigest = "c".repeat(64);
    const correlationId = "33333333-3333-4333-8333-333333333333";
    const secret = process.env.PARENT_TOKEN_PEPPER!;
    const proof = createHmac("sha256", secret).update(
      `parent-login-staging-session:v1\0${fixtureDigest}\0${correlationId}`,
      "utf8",
    ).digest("hex");
    const request = new Request("https://tenue.example/login", {
      headers: {
        "x-duindorp-staging-fixture-digest": fixtureDigest,
        "x-duindorp-staging-session-id": correlationId,
        "x-duindorp-staging-session-proof": proof,
      },
    });
    process.env.APP_ENVIRONMENT = "staging";
    process.env.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED = "true";
    expect(stagingAcceptanceSessionCorrelation(request)).toBe(
      createHmac("sha256", secret).update(
        `parent-login-staging-session-correlation:v1\0${fixtureDigest}\0${correlationId}`,
        "utf8",
      ).digest("hex"),
    );
    expect(stagingAcceptanceSessionCorrelation(new Request(request, {
      headers: {
        ...Object.fromEntries(request.headers),
        "x-duindorp-staging-session-proof": "d".repeat(64),
      },
    }))).toBeNull();
  });
});
