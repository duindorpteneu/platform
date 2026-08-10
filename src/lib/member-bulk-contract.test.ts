import { describe, expect, it } from "vitest";
import {
  MEMBER_BULK_CONTEXT_TTL_MS,
  memberBulkContextSchema,
  parseFreshMemberBulkContext,
} from "@/lib/member-bulk-contract";

const now = Date.parse("2026-08-03T20:00:00.000Z");
const context = {
  version: 1,
  source: "member_overview",
  target: "email",
  seasonId: "71000000-0000-4000-8000-000000000001",
  createdAt: new Date(now).toISOString(),
  expiresAt: new Date(now + MEMBER_BULK_CONTEXT_TTL_MS).toISOString(),
  entries: [{
    memberId: "74000000-0000-4000-8000-000000000001",
    memberSeasonId: "75000000-0000-4000-8000-000000000001",
    orderId: "76000000-0000-4000-8000-000000000001",
    team: "JO11-1",
  }],
} as const;

describe("member bulk context", () => {
  it("contains only bounded action identifiers and no member PII", () => {
    expect(memberBulkContextSchema.safeParse(context).success).toBe(true);
    const serialized = JSON.stringify(context);
    expect(serialized).not.toMatch(/"email":|memberName|relationNumber|dateOfBirth/);
  });

  it("is target-bound, short-lived and rejects duplicate member seasons", () => {
    expect(parseFreshMemberBulkContext(
      JSON.stringify(context),
      "email",
      now + 1_000,
    )).toEqual(context);
    expect(parseFreshMemberBulkContext(
      JSON.stringify(context),
      "portal_access",
      now + 1_000,
    )).toBeNull();
    expect(parseFreshMemberBulkContext(
      JSON.stringify(context),
      "email",
      now + MEMBER_BULK_CONTEXT_TTL_MS,
    )).toBeNull();
    expect(memberBulkContextSchema.safeParse({
      ...context,
      entries: [context.entries[0], context.entries[0]],
    }).success).toBe(false);
  });

  it("rejects a context whose claimed lifetime exceeds ten minutes", () => {
    expect(parseFreshMemberBulkContext(JSON.stringify({
      ...context,
      expiresAt: new Date(
        now + MEMBER_BULK_CONTEXT_TTL_MS + 1,
      ).toISOString(),
    }), "email", now + 1)).toBeNull();
  });
});
