import { describe, expect, it } from "vitest";
import { dashboardOverviewSchema, staffShellContextSchema } from "@/lib/dashboard-contract";

const validOverview = {
  activeSeason: { id: "10000000-0000-4000-8000-000000000001", name: "2026/27" },
  generatedAt: "2026-07-18T12:00:00.000Z",
  metrics: { totalMembers: 2, totalOrders: 2, paidOrders: 1, unpaidOrders: 1, partiallyReadyOrders: 1, fullyReadyOrders: 0, backorderOrders: 1, readyOrders: 1 },
  recentMembers: [{ orderId: "20000000-0000-4000-8000-000000000001", memberName: "Test Lid", team: "JO11-1", relationNumber: "TEST-1", paymentStatus: "Betaald", orderStatus: "Gedeeltelijk af te halen", progressQuantity: 1, totalQuantity: 2, updatedAt: "2026-07-18T12:00:00.000Z" }],
  activities: [{ id: 1, action: "stock.receipt.created", entityType: "delivery_receipt", createdAt: "2026-07-18T12:00:00.000Z" }],
};

describe("dashboard overview contract", () => {
  it("accepts only a minimal staff shell context", () => {
    expect(staffShellContextSchema.safeParse({ activeSeason: validOverview.activeSeason }).success).toBe(true);
    expect(staffShellContextSchema.safeParse({ activeSeason: validOverview.activeSeason, memberCount: 2 }).success).toBe(false);
  });

  it("accepts the minimal operational aggregate", () => {
    expect(dashboardOverviewSchema.safeParse(validOverview).success).toBe(true);
  });

  it("accepts an empty season state", () => {
    expect(dashboardOverviewSchema.safeParse({ ...validOverview, activeSeason: null, recentMembers: [], activities: [] }).success).toBe(true);
  });

  it("rejects PII and impossible counters", () => {
    const withEmail = { ...validOverview, recentMembers: [{ ...validOverview.recentMembers[0], email: "ouder@example.invalid" }] };
    expect(dashboardOverviewSchema.safeParse(withEmail).success).toBe(false);
    expect(dashboardOverviewSchema.safeParse({ ...validOverview, metrics: { ...validOverview.metrics, paidOrders: -1 } }).success).toBe(false);
  });
});
