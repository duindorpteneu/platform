import { describe, expect, it } from "vitest";
import { manualPaymentRequestSchema } from "@/server/payments/manual";

describe("manual payment boundary", () => {
  it("accepts only order and fixed payment method", () => {
    const result = manualPaymentRequestSchema.safeParse({ orderId: "00000000-0000-4000-8000-000000000001", method: "cash" });
    expect(result.success).toBe(true);
  });

  it("rejects a browser-supplied amount", () => {
    const result = manualPaymentRequestSchema.safeParse({ orderId: "00000000-0000-4000-8000-000000000001", method: "card", amountCents: 1 });
    expect(result.success).toBe(false);
  });
});
