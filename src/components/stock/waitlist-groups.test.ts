import { describe, expect, it } from "vitest";
import { groupWaitlistByOrder, type WaitlistLine } from "./waitlist-groups";

function line(overrides: Partial<WaitlistLine> = {}): WaitlistLine {
  return {
    orderLineId: "line-1",
    orderId: "order-1",
    memberName: "Bentley Goldenbelt",
    relationNumber: null,
    team: "Duindorp sv O13-1JM",
    variantId: "variant-1",
    article: "Wedstrijdshirt",
    size: "L",
    sku: null,
    quantity: 1,
    paid: false,
    sizeValid: false,
    fifoAt: null,
    eligible: false,
    createdAt: "2026-08-16T08:00:00.000Z",
    ...overrides,
  };
}

describe("groupWaitlistByOrder", () => {
  it("groepeert pakketregels per bestelling en bewaart de FIFO-regelvolgorde", () => {
    const result = groupWaitlistByOrder([
      line(),
      line({ orderLineId: "line-2", variantId: "variant-2", article: "Wedstrijdbroek" }),
      line({ orderLineId: "line-3", variantId: "variant-3", article: "Sokken" }),
    ]);

    expect(result).toHaveLength(1);
    expect(result[0]?.lines.map((item) => item.article)).toEqual([
      "Wedstrijdshirt",
      "Wedstrijdbroek",
      "Sokken",
    ]);
  });

  it("voegt naamgenoten met verschillende bestellingen niet samen", () => {
    const result = groupWaitlistByOrder([
      line(),
      line({ orderLineId: "line-2", orderId: "order-2" }),
    ]);

    expect(result.map((group) => group.orderId)).toEqual(["order-1", "order-2"]);
  });

  it("bewaart de volgorde waarin bestellingen voor het eerst in de FIFO-respons staan", () => {
    const result = groupWaitlistByOrder([
      line({ orderLineId: "line-2", orderId: "order-2", memberName: "Tweede" }),
      line({ orderLineId: "line-1", orderId: "order-1", memberName: "Eerste" }),
      line({ orderLineId: "line-3", orderId: "order-2", memberName: "Tweede" }),
    ]);

    expect(result.map((group) => group.memberName)).toEqual(["Tweede", "Eerste"]);
    expect(result[0]?.lines.map((item) => item.orderLineId)).toEqual(["line-2", "line-3"]);
  });
});
