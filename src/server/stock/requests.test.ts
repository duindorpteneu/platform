import { describe, expect, it } from "vitest";
import {
  deliveryReceiptRequestSchema,
  inventoryDraftCreateSchema,
  inventoryDraftUpdateSchema,
  stockReservationRequestSchema,
} from "@/server/stock/requests";

const firstId = "00000000-0000-4000-8000-000000000001";
const secondId = "00000000-0000-4000-8000-000000000002";

describe("stock request boundaries", () => {
  it("accepts a bounded receipt with unique variants", () => {
    const result = deliveryReceiptRequestSchema.safeParse({
      receivedOn: "2026-07-18",
      supplier: "Kledingleverancier",
      packingSlipReference: "PB-1042",
      lines: [{ variantId: firstId, quantity: 24 }],
    });
    expect(result.success).toBe(true);
  });

  it("rejects impossible dates and duplicate variants", () => {
    const result = deliveryReceiptRequestSchema.safeParse({
      receivedOn: "2026-02-31",
      supplier: "Kledingleverancier",
      lines: [{ variantId: firstId, quantity: 2 }, { variantId: firstId, quantity: 3 }],
    });
    expect(result.success).toBe(false);
  });

  it("rejects duplicate order lines in one reservation", () => {
    const result = stockReservationRequestSchema.safeParse({ receiptLineId: firstId, orderLineIds: [firstId, firstId] });
    expect(result.success).toBe(false);
  });

  it("accepts a retry-stable delivery draft with selected products", () => {
    expect(inventoryDraftCreateSchema.safeParse({
      seasonId: firstId,
      receivedOn: "2026-08-03",
      supplier: "Free-Kick Sport",
      articleIds: [firstId, secondId],
      requestId: secondId,
    }).success).toBe(true);
  });

  it("requires the caller to send each generated size row exactly once", () => {
    expect(inventoryDraftUpdateSchema.safeParse({
      expectedRevision: 2,
      requestId: firstId,
      lines: [
        { variantId: firstId, quantity: 0, confirmed: true },
        { variantId: firstId, quantity: 1, confirmed: true },
      ],
    }).success).toBe(false);
  });

  it("does not allow confirmation without a number or explicit zero", () => {
    expect(inventoryDraftUpdateSchema.safeParse({
      expectedRevision: 2,
      requestId: firstId,
      lines: [{ variantId: secondId, quantity: null, confirmed: true }],
    }).success).toBe(false);
  });
});
