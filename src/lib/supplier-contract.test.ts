import { describe, expect, it } from "vitest";
import {
  SUPPLIER_FORBIDDEN_RESPONSE_KEYS,
  supplierPlanningSchema,
} from "@/lib/supplier-contract";

function allKeys(value: unknown): string[] {
  if (Array.isArray(value)) return value.flatMap(allKeys);
  if (!value || typeof value !== "object") return [];
  return Object.entries(value).flatMap(([key, child]) => [
    key,
    ...allKeys(child),
  ]);
}

describe("supplier planning contract", () => {
  it("houdt de externe keyspace vrij van individuele PII", () => {
    const shape = {
      season: { id: crypto.randomUUID(), name: "2026/2027" },
      generatedAt: new Date().toISOString(),
      lowStockThreshold: 10,
      inventory: [],
      demandByGender: [],
      unresolvedSizeDemand: [],
    };
    expect(supplierPlanningSchema.safeParse(shape).success).toBe(true);
    expect(allKeys(shape)).not.toEqual(expect.arrayContaining(
      [...SUPPLIER_FORBIDDEN_RESPONSE_KEYS],
    ));
    expect(supplierPlanningSchema.safeParse({
      ...shape,
      orderId: crypto.randomUUID(),
    }).success).toBe(false);
  });

  it("accepteert alleen de vier expliciete genderwaarden", () => {
    const base = {
      season: { id: crypto.randomUUID(), name: "2026/2027" },
      generatedAt: new Date().toISOString(),
      lowStockThreshold: 10,
      inventory: [],
      unresolvedSizeDemand: [],
    };
    const row = {
      productName: "Broek",
      productCode: "BROEK",
      size: "M",
      supplierCode: null,
      totalOpenDemand: 1,
      paidWaiting: 0,
      unpaidDemand: 1,
      unconfirmedDemand: 0,
      pickedUp: 0,
    };
    for (const gender of ["male", "female", "other", "unknown"]) {
      expect(supplierPlanningSchema.safeParse({
        ...base,
        demandByGender: [{ ...row, gender }],
      }).success).toBe(true);
    }
    expect(supplierPlanningSchema.safeParse({
      ...base,
      demandByGender: [{ ...row, gender: "guessed" }],
    }).success).toBe(false);
  });
});
