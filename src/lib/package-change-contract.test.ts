import { describe, expect, it } from "vitest";
import {
  packageChangeRequestSchema,
  packageChangeResponseSchema,
} from "./package-change-contract";

const requestId = "10000000-0000-4000-8000-000000000001";

describe("package change contract", () => {
  it("requires an explicit audited preflight reason", () => {
    expect(packageChangeRequestSchema.safeParse({
      action: "preflight",
      orderId: requestId,
      targetPackageRevisionId:
        "20000000-0000-4000-8000-000000000001",
      reason: "Controle met lid",
      requestId: "30000000-0000-4000-8000-000000000001",
    }).success).toBe(true);
    expect(packageChangeRequestSchema.safeParse({
      action: "preflight",
      orderId: requestId,
      targetPackageRevisionId:
        "20000000-0000-4000-8000-000000000001",
      reason: "",
      requestId: "30000000-0000-4000-8000-000000000001",
    }).success).toBe(false);
    expect(packageChangeRequestSchema.safeParse({
      action: "preflight",
      orderId: requestId,
      targetPackageRevisionId:
        "20000000-0000-4000-8000-000000000001",
      reason: "x".repeat(481),
      requestId: "30000000-0000-4000-8000-000000000001",
    }).success).toBe(false);
  });

  it("models credit, remaining balance and explicit refund obligations", () => {
    const base = {
      requestId,
      orderId: "20000000-0000-4000-8000-000000000001",
      memberSeasonId: "30000000-0000-4000-8000-000000000001",
      fromSnapshotId: "40000000-0000-4000-8000-000000000001",
      fromPackageRevisionId: null,
      fromPackageName: "Speler",
      fromPriceCents: 10000,
      fromCurrency: "EUR",
      toPackageRevisionId: "50000000-0000-4000-8000-000000000001",
      toPackageName: "Keeper",
      toPriceCents: 12500,
      toCurrency: "EUR",
      priceDeltaCents: 2500,
      effectivePaidCents: 10000,
      creditAvailableCents: 10000,
      creditAppliedCents: 10000,
      additionalDueCents: 2500,
      refundDueCents: 0,
      paymentMethod: "cash",
      paymentSources: [{
        paymentId: "70000000-0000-4000-8000-000000000001",
        method: "cash",
        amountCents: 10000,
        paidAt: "2026-08-20T12:00:00Z",
      }],
      unresolvedPaymentCount: 0,
      reservedAllocationCount: 0,
      fulfilledAllocationCount: 0,
      requiresAllocationRelease: false,
      blockedByFulfilment: false,
      blockedByReconciliation: false,
      targetPackageRequiredSizeCount: 2,
      targetPackageKnownSizeCount: 1,
      targetPackageMissingSizeCount: 1,
      canApply: true,
      status: "ready",
      revision: "a".repeat(64),
      reused: false,
      result: null,
    };
    expect(packageChangeResponseSchema.safeParse(base).success).toBe(true);
    expect(packageChangeResponseSchema.safeParse({
      ...base,
      result: {
        requestId,
        adjustmentId: "80000000-0000-4000-8000-000000000001",
        orderId: base.orderId,
        memberSeasonId: base.memberSeasonId,
        fromSnapshotId: base.fromSnapshotId,
        toSnapshotId: "60000000-0000-4000-8000-000000000001",
        toPackageRevisionId: base.toPackageRevisionId,
        priceDeltaCents: 2500,
        creditAppliedCents: 10000,
        additionalDueCents: 2500,
        refundDueCents: 0,
        releasedAllocationCount: 0,
        targetSizesConfirmed: false,
        materialization: { orderLinesMaterialized: 0, snapshotItemsLinked: 0 },
        paymentTransferred: true,
        refunds: [],
        status: "applied",
      },
    }).success).toBe(false);
  });
});
