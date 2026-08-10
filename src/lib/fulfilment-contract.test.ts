import { describe, expect, it } from "vitest";
import {
  formatIssuanceGender,
  fulfilmentExchangeResponseSchema,
} from "@/lib/fulfilment-contract";

const found = {
  status: "found" as const,
  grantExpiresAt: "2026-08-03T12:02:00.000Z",
  member: {
    firstName: "Noa",
    gender: "unknown" as const,
  },
  lines: [{
    id: "20000000-0000-4000-8000-000000000001",
    article: "Shirt",
    size: "152",
    quantity: 1,
    status: "ready_for_pickup" as const,
  }],
  scanGrant: `sg2.k1.${"a".repeat(43)}`,
};

describe("fulfilment exchange contract", () => {
  it("accepts only the minimal scanner workspace", () => {
    expect(fulfilmentExchangeResponseSchema.safeParse(found).success).toBe(true);
    expect(formatIssuanceGender(found.member.gender)).toBe(
      "Niet geregistreerd",
    );
  });

  it.each([
    { member: { ...found.member, lastName: "Tester" } },
    { member: { ...found.member, dateOfBirth: "2012-03-04" } },
    { member: { ...found.member, email: "noa@example.invalid" } },
    { member: { ...found.member, team: "JO13-1" } },
    { member: { ...found.member, relationNumber: "1234567" } },
    { orderId: "10000000-0000-4000-8000-000000000001" },
    { amountCents: 12500 },
  ])("rejects extra scanner data %#", (extra) => {
    expect(fulfilmentExchangeResponseSchema.safeParse({
      ...found,
      ...extra,
    }).success).toBe(false);
  });

  it("uses one uniform invalid response", () => {
    expect(fulfilmentExchangeResponseSchema.parse({
      status: "invalid",
    })).toEqual({ status: "invalid" });
  });
});
