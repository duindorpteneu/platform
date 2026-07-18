import { describe, expect, it } from "vitest";
import { fulfilmentCorrectionsWorkspaceSchema } from "@/lib/fulfilment-corrections-contract";

describe("uitgiftecorrectiecontract", () => {
  it("accepteert een lege historie", () => {
    expect(fulfilmentCorrectionsWorkspaceSchema.parse({ fulfilments: [] })).toEqual({ fulfilments: [] });
  });
  it("weigert persoonsgegevens buiten het minimale readmodel", () => {
    expect(fulfilmentCorrectionsWorkspaceSchema.safeParse({ fulfilments: [{
      id: "10000000-0000-4000-8000-000000000001", orderId: "10000000-0000-4000-8000-000000000002",
      memberName: "Test Lid", relationNumber: "DSV-1", team: "JO11-1", location: "Clubhuis",
      fulfilledAt: "2026-07-18T12:00:00Z", correctedAt: null, lines: [], email: "niet-nodig@example.invalid",
    }] }).success).toBe(false);
  });
});

