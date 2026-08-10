import { describe, expect, it } from "vitest";
import { paymentWorkspaceSchema } from "@/lib/payment-workspace-contract";

const valid = {
  canRecordRefund: true,
  summary: { open: 1, pending: 0, paid: 2, duplicatePaid: 0, refunded: 0, review: 0 },
  attempts: [{
    paymentId: "10000000-0000-4000-8000-000000000001",
    orderId: "10000000-0000-4000-8000-000000000002",
    memberName: "Fenna Voorbeeld",
    relationNumber: "DSV-1001",
    team: "JO13-1",
    method: "mollie",
    status: "paid",
    amountCents: 12500,
    currency: "EUR",
    providerPaymentId: "tr_test123",
    reconciliationIssue: null,
    createdAt: "2026-07-18T10:00:00.000Z",
    reconciledAt: "2026-07-18T10:01:00.000Z",
  }],
};

describe("payment workspace contract", () => {
  it("accepts a PII-minimal operational response", () => {
    expect(paymentWorkspaceSchema.parse(valid).attempts[0].status).toBe("paid");
  });

  it("rejects leaked recipient or checkout data", () => {
    expect(paymentWorkspaceSchema.safeParse({ ...valid, attempts: [{ ...valid.attempts[0], email: "ouder@example.test" }] }).success).toBe(false);
    expect(paymentWorkspaceSchema.safeParse({ ...valid, attempts: [{ ...valid.attempts[0], checkoutUrl: "https://mollie.example" }] }).success).toBe(false);
  });
});
