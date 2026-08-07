import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getProposal: vi.fn(),
  confirmProposal: vi.fn(),
}));

vi.mock("@/server/stock/delivery-notifications", () => ({
  getDeliveryNotificationProposal: mocks.getProposal,
  confirmDeliveryNotificationProposal: mocks.confirmProposal,
}));
vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({ APP_BASE_URL: "https://tenue.example" }),
}));

import { GET, POST } from "./route";

const draftId = "d4200000-0000-4000-8000-000000000001";
const proposalId = "d4200000-0000-4000-8000-000000000002";
const itemId = "d4200000-0000-4000-8000-000000000003";
const requestId = "d4200000-0000-4000-8000-000000000004";
const revision = "c".repeat(64);

const proposal = {
  id: proposalId,
  deliveryDraftId: draftId,
  status: "open",
};

function postRequest(body: unknown) {
  return new Request(
    `https://tenue.example/api/stock/drafts/${draftId}/notifications`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://tenue.example",
        Host: "tenue.example",
        "Sec-Fetch-Site": "same-origin",
        "X-Duindorp-CSRF": "same-origin",
        "X-Correlation-Id": requestId,
      },
      body: JSON.stringify(body),
    },
  );
}

const context = { params: Promise.resolve({ draftId }) };

describe("delivery notification proposal route", () => {
  beforeEach(() => {
    mocks.getProposal.mockReset().mockResolvedValue({
      data: proposal,
      error: null,
    });
    mocks.confirmProposal.mockReset().mockResolvedValue({
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
  });

  it("levert een no-store preview", async () => {
    const response = await GET(
      new Request(
        `https://tenue.example/api/stock/drafts/${draftId}/notifications`,
      ),
      context,
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.getProposal).toHaveBeenCalledWith(draftId);
  });

  it("bevestigt alleen een voorstel dat aan het routeconcept is gebonden", async () => {
    const input = {
      proposalId,
      expectedRevision: revision,
      excludedItemIds: [],
      requestId,
    };
    const response = await POST(postRequest(input), context);

    expect(response.status).toBe(201);
    expect(mocks.confirmProposal).toHaveBeenCalledWith(input, requestId);
  });

  it("weigert duplicaten en vertaalt doelgroepdrift zonder SQL-details", async () => {
    const duplicate = await POST(postRequest({
      proposalId,
      expectedRevision: revision,
      excludedItemIds: [itemId, itemId],
      requestId,
    }), context);
    expect(duplicate.status).toBe(400);
    expect(mocks.confirmProposal).not.toHaveBeenCalled();

    mocks.confirmProposal.mockResolvedValueOnce({
      data: null,
      error: {
        code: "40001",
        message: "DELIVERY_NOTIFICATION_ELIGIBILITY_CHANGED",
      },
    });
    const stale = await POST(postRequest({
      proposalId,
      expectedRevision: revision,
      excludedItemIds: [],
      requestId,
    }), context);
    expect(stale.status).toBe(409);
    expect(JSON.stringify(await stale.json())).not.toContain(
      "DELIVERY_NOTIFICATION_ELIGIBILITY_CHANGED",
    );
  });
});
