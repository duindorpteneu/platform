import { describe, expect, it } from "vitest";
import { normalizeParentEmail, parentCodeSchema, parentEmailSchema } from "@/server/auth/parent";

describe("parent authentication boundary", () => {
  it("normalizes parent email addresses", () => {
    expect(normalizeParentEmail("  OUDER@Example.NL ")).toBe("ouder@example.nl");
    expect(parentEmailSchema.safeParse({ email: "ouder@example.nl" }).success).toBe(true);
  });

  it("accepts exactly six numeric digits", () => {
    expect(parentCodeSchema.safeParse({ email: "ouder@example.nl", code: "123456" }).success).toBe(true);
    expect(parentCodeSchema.safeParse({ email: "ouder@example.nl", code: "12345" }).success).toBe(false);
    expect(parentCodeSchema.safeParse({ email: "ouder@example.nl", code: "1234567" }).success).toBe(false);
  });
});
