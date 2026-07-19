import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { normalizeParentEmail, openParentChallengeEmail, parentCodeInputSchema, parentCodeSchema, parentEmailSchema, sealParentChallengeEmail } from "@/server/auth/parent";

describe("parent authentication boundary", () => {
  beforeEach(() => { process.env.PARENT_TOKEN_PEPPER = "test-parent-pepper-with-thirty-two-characters"; });
  afterEach(() => { delete process.env.PARENT_TOKEN_PEPPER; });
  it("normalizes parent email addresses", () => {
    expect(normalizeParentEmail("  OUDER@Example.NL ")).toBe("ouder@example.nl");
    expect(parentEmailSchema.safeParse({ email: "ouder@example.nl" }).success).toBe(true);
  });

  it("accepts exactly six numeric digits", () => {
    expect(parentCodeSchema.safeParse({ email: "ouder@example.nl", code: "123456" }).success).toBe(true);
    expect(parentCodeSchema.safeParse({ email: "ouder@example.nl", code: "12345" }).success).toBe(false);
    expect(parentCodeSchema.safeParse({ email: "ouder@example.nl", code: "1234567" }).success).toBe(false);
    expect(parentCodeInputSchema.safeParse({ code: "123456" }).success).toBe(true);
  });

  it("keeps the OTP e-mail out of URLs through an opaque expiring challenge", () => {
    const token = sealParentChallengeEmail("OUDER@example.nl", 1_000);
    expect(token).not.toContain("ouder");
    expect(openParentChallengeEmail(token, 2_000)).toBe("ouder@example.nl");
    expect(openParentChallengeEmail(token, 10 * 60 * 1000 + 1_001)).toBeNull();
    expect(openParentChallengeEmail(`${token}tampered`, 2_000)).toBeNull();
  });
});
