import { describe, expect, it } from "vitest";
import {
  mollieCheckoutResponseSchema,
  mollieCreateRequestSchema,
  preparedMolliePaymentSchema,
} from "@/lib/mollie-contract";

const ids = {
  payment: "00000000-0000-4000-8000-000000000001",
  order: "00000000-0000-4000-8000-000000000002",
  member: "00000000-0000-4000-8000-000000000003",
  season: "00000000-0000-4000-8000-000000000004",
  memberSeason: "00000000-0000-4000-8000-000000000005",
};

describe("Mollie-contract", () => {
  it("accepteert alleen een order-id van de browser", () => {
    expect(mollieCreateRequestSchema.parse({ orderId: ids.order })).toEqual({ orderId: ids.order });
    expect(mollieCreateRequestSchema.safeParse({ orderId: ids.order, amountCents: 1 }).success).toBe(false);
  });

  it("weigert een checkout zonder HTTPS", () => {
    expect(mollieCheckoutResponseSchema.safeParse({ checkoutUrl: "http://mollie.test/checkout" }).success).toBe(false);
    expect(mollieCheckoutResponseSchema.safeParse({ checkoutUrl: "https://aanvaller.invalid/checkout" }).success).toBe(false);
    expect(mollieCheckoutResponseSchema.safeParse({ checkoutUrl: "https://www.mollie.com/checkout/test" }).success).toBe(true);
  });

  it("weigert lokale betaalmetadata die niet bij de poging hoort", () => {
    const result = preparedMolliePaymentSchema.safeParse({
      paymentId: ids.payment,
      orderId: ids.order,
      amountCents: 7500,
      currency: "EUR",
      status: "open",
      providerPaymentId: null,
      checkoutUrl: null,
      reused: false,
      idempotencyKey: "mollie-local-attempt",
      metadata: {
        payment_id: "00000000-0000-4000-8000-000000000099",
        order_id: ids.order,
        member_id: ids.member,
        member_season_id: ids.memberSeason,
        season_id: ids.season,
        schema_version: 2,
      },
    });

    expect(result.success).toBe(false);
  });
});
