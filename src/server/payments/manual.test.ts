import { describe, expect, it } from "vitest";
import { manualPaymentRequestSchema } from "@/server/payments/manual";

describe("manual payment boundary", () => {
  const valid = {
    orderId: "00000000-0000-4000-8000-000000000001",
    method: "cash",
    amountCents: 12_500,
    reason: "Contant ontvangen",
    requestId: "00000000-0000-4000-8000-000000000002",
  } as const;

  it("vereist exact bedrag, reden en stabiele request-id", () => {
    const result = manualPaymentRequestSchema.safeParse(valid);
    expect(result.success).toBe(true);
  });

  it("weigert ontbrekende of onbegrensde registratiecontext", () => {
    expect(manualPaymentRequestSchema.safeParse({ orderId: valid.orderId, method: "cash" }).success).toBe(false);
    expect(manualPaymentRequestSchema.safeParse({ ...valid, reason: "x" }).success).toBe(false);
    expect(manualPaymentRequestSchema.safeParse({ ...valid, amountCents: 0 }).success).toBe(false);
    expect(manualPaymentRequestSchema.safeParse({ ...valid, extra: true }).success).toBe(false);
  });
});
