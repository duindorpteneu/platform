import { describe, expect, it } from "vitest";
import { parentMemberLinkSchema } from "@/server/auth/parent-links";

describe("parent member links", () => {
  it("accepts only a member UUID", () => {
    expect(parentMemberLinkSchema.safeParse({ memberId: "00000000-0000-4000-8000-000000000001" }).success).toBe(true);
    expect(parentMemberLinkSchema.safeParse({ memberId: "not-a-member", extra: true }).success).toBe(false);
  });
});
