import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireStaffRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: vi.fn(async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  })),
}));

import {
  confirmDeliveryNotificationProposal,
  getDeliveryNotificationProposal,
} from "@/server/stock/delivery-notifications";

const proposalId = "d4100000-0000-4000-8000-000000000001";
const draftId = "d4100000-0000-4000-8000-000000000002";
const itemId = "d4100000-0000-4000-8000-000000000003";
const requestId = "d4100000-0000-4000-8000-000000000004";
const revision = "b".repeat(64);

const proposal = {
  id: proposalId,
  deliveryDraftId: draftId,
  seasonId: "d4100000-0000-4000-8000-000000000005",
  receiptId: "d4100000-0000-4000-8000-000000000006",
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
    allocationEventId: "d4100000-0000-4000-8000-000000000007",
    allocationId: "d4100000-0000-4000-8000-000000000008",
    productName: "Broek",
    size: "152",
    quantity: 1,
    classification: "eligible",
    reasonCode: "notification.ready",
    eventCount: 0,
    selectedByDefault: true,
  }],
};

describe("delivery notification service", () => {
  beforeEach(() => {
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      role: "kledingcommissie",
    });
    mocks.rpc.mockReset();
  });

  it("leest alleen het PII-vrije voorstel via de gebonden RPC", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: proposal, error: null });
    const result = await getDeliveryNotificationProposal(draftId);

    expect(result.data).toEqual(proposal);
    expect(JSON.stringify(result.data)).not.toContain("email");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_inventory_delivery_notification_proposal_v1",
      { p_delivery_draft_id: draftId },
    );
  });

  it("bevestigt de exacte selectie met correlatie-ID", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        proposalId,
        status: "confirmed",
        selectedCount: 1,
        eligibleCount: 1,
        skippedCount: 0,
        blockedCount: 0,
        eventCount: 1,
        parentGroupCount: 1,
        reused: false,
      },
      error: null,
    });
    const input = {
      proposalId,
      expectedRevision: revision,
      excludedItemIds: [],
      requestId,
    };
    const result = await confirmDeliveryNotificationProposal(input, requestId);

    expect(result.data?.eventCount).toBe(1);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "confirm_inventory_delivery_notification_proposal_v1",
      {
        p_proposal_id: proposalId,
        p_expected_revision: revision,
        p_excluded_item_ids: [],
        p_request_id: requestId,
        p_correlation_id: requestId,
      },
    );
  });
});
