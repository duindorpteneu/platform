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

  it("never permits a payment transfer or automatic refund in responses", () => {
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
      paymentStatus: "refunded",
      unresolvedPaymentCount: 0,
      paidHistoryCount: 1,
      refundedPaymentCount: 1,
      reservedAllocationCount: 0,
      fulfilledAllocationCount: 0,
      requiresPaymentResolution: false,
      requiresExternalRefund: false,
      requiresAllocationRelease: false,
      blockedByFulfilment: false,
      blockedByReconciliation: false,
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
        orderId: base.orderId,
        memberSeasonId: base.memberSeasonId,
        fromSnapshotId: base.fromSnapshotId,
        toSnapshotId: "60000000-0000-4000-8000-000000000001",
        toPackageRevisionId: base.toPackageRevisionId,
        priceDeltaCents: 2500,
        releasedAllocationCount: 0,
        paymentTransferred: true,
        refundCreated: false,
        status: "applied",
      },
    }).success).toBe(false);
  });
});
