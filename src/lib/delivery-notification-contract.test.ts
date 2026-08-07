import { describe, expect, it } from "vitest";
import {
  deliveryNotificationConfirmRequestSchema,
  deliveryNotificationProposalSchema,
} from "@/lib/delivery-notification-contract";

const proposalId = "d4000000-0000-4000-8000-000000000001";
const itemId = "d4000000-0000-4000-8000-000000000002";
const eventId = "d4000000-0000-4000-8000-000000000003";
const allocationId = "d4000000-0000-4000-8000-000000000004";
const revision = "a".repeat(64);

describe("delivery notification contract", () => {
  it("accepts a PII-free proposal with dynamic eligibility", () => {
    expect(deliveryNotificationProposalSchema.safeParse({
      id: proposalId,
      deliveryDraftId: "d4000000-0000-4000-8000-000000000005",
      seasonId: "d4000000-0000-4000-8000-000000000006",
      receiptId: "d4000000-0000-4000-8000-000000000007",
      status: "open",
      eligibilityRevision: revision,
      selectedCount: 0,
      eligibleCount: 1,
      skippedCount: 0,
      blockedCount: 0,
      eventCount: 0,
      parentGroupCount: 1,
      createdAt: "2026-08-03T12:00:00.000Z",
      confirmedAt: null,
      items: [{
        id: itemId,
        allocationEventId: eventId,
        allocationId,
        productName: "Wedstrijdshirt",
        size: "152",
        quantity: 1,
        classification: "eligible",
        reasonCode: "notification.ready",
        eventCount: 0,
        selectedByDefault: true,
      }],
    }).success).toBe(true);
  });

  it("rejects duplicate selections and PII-shaped extra fields", () => {
    expect(deliveryNotificationConfirmRequestSchema.safeParse({
      proposalId,
      expectedRevision: revision,
      excludedItemIds: [itemId, itemId],
      requestId: eventId,
    }).success).toBe(false);

    expect(deliveryNotificationProposalSchema.safeParse({
      id: proposalId,
      email: "ouder@example.invalid",
    }).success).toBe(false);
  });

  it("kan alle geschikte regels impliciet selecteren boven de UI-batchgrens", () => {
    const item = {
      id: itemId,
      allocationEventId: eventId,
      allocationId,
      productName: "Wedstrijdshirt",
      size: "152",
      quantity: 1,
      classification: "eligible" as const,
      reasonCode: "notification.ready",
      eventCount: 0,
      selectedByDefault: true,
    };
    expect(deliveryNotificationProposalSchema.safeParse({
      id: proposalId,
      deliveryDraftId: "d4000000-0000-4000-8000-000000000005",
      seasonId: "d4000000-0000-4000-8000-000000000006",
      receiptId: "d4000000-0000-4000-8000-000000000007",
      status: "open",
      eligibilityRevision: revision,
      selectedCount: 0,
      eligibleCount: 501,
      skippedCount: 0,
      blockedCount: 0,
      eventCount: 0,
      parentGroupCount: 0,
      createdAt: "2026-08-03T12:00:00.000Z",
      confirmedAt: null,
      items: Array.from({ length: 501 }, (_, index) => ({
        ...item,
        id: `d4${String(index).padStart(6, "0")}-0000-4000-8000-000000000002`,
      })),
    }).success).toBe(true);
    expect(deliveryNotificationConfirmRequestSchema.safeParse({
      proposalId,
      expectedRevision: revision,
      excludedItemIds: [],
      requestId: eventId,
    }).success).toBe(true);
  });
});
