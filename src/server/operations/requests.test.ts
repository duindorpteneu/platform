import { describe, expect, it } from "vitest";
import { fulfilmentCorrectionRequestSchema, qrManagementRequestSchema } from "@/server/operations/requests";

const id = "10000000-0000-4000-8000-000000000001";

describe("operationele correctiecontracten", () => {
  it("normaliseert een geldige QR-reden", () => {
    expect(qrManagementRequestSchema.parse({ orderId: id, action: "rotate", reason: "  Code kwijt  " }).reason).toBe("Code kwijt");
  });

  it("weigert een lege reden en extra browservelden", () => {
    expect(qrManagementRequestSchema.safeParse({ orderId: id, action: "revoke", reason: "   " }).success).toBe(false);
    expect(qrManagementRequestSchema.safeParse({ orderId: id, action: "rotate", reason: "Code kwijt", tokenHash: "x" }).success).toBe(false);
  });

  it("accepteert uitsluitend unieke correctieregels en canonieke doelstatussen", () => {
    expect(fulfilmentCorrectionRequestSchema.safeParse({ orderLineIds: [id], targetStatus: "backorder", reason: "Verkeerd uitgegeven" }).success).toBe(true);
    expect(fulfilmentCorrectionRequestSchema.safeParse({ orderLineIds: [id, id], targetStatus: "ready_for_pickup", reason: "Dubbele selectie" }).success).toBe(false);
    expect(fulfilmentCorrectionRequestSchema.safeParse({ orderLineIds: [id], targetStatus: "picked_up", reason: "Onjuiste status" }).success).toBe(false);
  });
});
