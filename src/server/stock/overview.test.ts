import { describe, expect, it } from "vitest";
import { stockOverviewQuerySchema } from "@/server/stock/overview";

describe("stock overview query", () => {
  it("accepts an optional variant filter", () => {
    expect(stockOverviewQuerySchema.safeParse({ variantId: "00000000-0000-4000-8000-000000000001" }).success).toBe(true);
    expect(stockOverviewQuerySchema.safeParse({}).success).toBe(true);
  });

  it("rejects arbitrary filters", () => {
    expect(stockOverviewQuerySchema.safeParse({ variantId: "shirt", includeParents: true }).success).toBe(false);
  });
});
