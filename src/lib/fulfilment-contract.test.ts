import { describe, expect, it } from "vitest";
import {
  formatLegacyIssuanceMemberMeta,
  fulfilmentLookupResponseSchema,
} from "@/lib/fulfilment-contract";

const found = {
  status: "found" as const,
  orderId: "10000000-0000-4000-8000-000000000001",
  paid: true,
  member: {
    name: "Noa Tester",
    team: "JO13-1",
    relationNumberSuffix: null,
  },
  lines: [{
    id: "20000000-0000-4000-8000-000000000001",
    article: "Shirt",
    size: "152",
    status: "ready_for_pickup" as const,
  }],
};

describe("fulfilment lookup contract", () => {
  it("accepts a member without a relation number and renders no null suffix", () => {
    expect(fulfilmentLookupResponseSchema.safeParse(found).success).toBe(true);
    expect(formatLegacyIssuanceMemberMeta(found.member)).toBe(
      "JO13-1 · geen relatienummer",
    );
  });

  it("rejects extra PII at the issuance boundary", () => {
    expect(fulfilmentLookupResponseSchema.safeParse({
      ...found,
      member: {
        ...found.member,
        dateOfBirth: "2012-03-04",
      },
    }).success).toBe(false);
  });
});
