import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  preview: vi.fn(),
  confirm: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-campaigns", () => ({
  previewMailV2Campaign: mocks.preview,
  confirmMailV2Campaign: mocks.confirm,
}));

import { POST } from "./route";

const orderId = "74000000-0000-4000-8000-000000000001";
const requestId = "74000000-0000-4000-8000-000000000002";
const preflightId = "74000000-0000-4000-8000-000000000003";
const revision = "d".repeat(64);

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/campaigns", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": requestId,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/email/v2/campaigns", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.preview.mockReset().mockResolvedValue({
      data: {
        preflightId,
        templateKey: "payment_request",
        seasonId: "74000000-0000-4000-8000-000000000004",
        eligibilityRevision: revision,
        selectedTargetCount: 1,
        eligibleTargetCount: 1,
        eligibleEventCount: 1,
        skippedTargetCount: 0,
        blockedTargetCount: 0,
        parentGroupCount: 1,
        expiresAt: "2026-08-03T18:00:00.000Z",
        preview: {
          subject: "Betaalverzoek voor Test",
          preheader: "Betaal het pakketbedrag.",
          html: "<p>Veilige voorbeeldtekst</p>",
          text: "Veilige voorbeeldtekst",
        },
        reused: false,
      },
      error: null,
    });
    mocks.confirm.mockReset().mockResolvedValue({
      data: {
        runId: "74000000-0000-4000-8000-000000000005",
        templateKey: "payment_request",
        eventCount: 1,
        parentGroupCount: 1,
        reused: false,
      },
      error: null,
    });
  });

  it("maakt een actor-bound preflight met unieke orders", async () => {
    const input = {
      action: "preview",
      templateKey: "payment_request",
      targetIds: [orderId],
      requestId,
    } as const;
    const response = await POST(request(input));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.preview).toHaveBeenCalledWith(input);
    expect(mocks.confirm).not.toHaveBeenCalled();
  });

  it("bevestigt alleen met de exacte preflightrevisie", async () => {
    const input = {
      action: "confirm",
      preflightId,
      expectedRevision: revision,
      requestId,
    } as const;
    const response = await POST(request(input));

    expect(response.status).toBe(201);
    expect(mocks.confirm).toHaveBeenCalledWith(input, requestId);
  });

  it("weigert duplicaten en vertaalt doelgroepdrift zonder SQL-details", async () => {
    const invalid = await POST(request({
      action: "preview",
      templateKey: "payment_request",
      targetIds: [orderId, orderId],
      requestId,
    }));
    expect(invalid.status).toBe(400);
    expect(mocks.preview).not.toHaveBeenCalled();

    mocks.confirm.mockResolvedValueOnce({
      data: null,
      error: {
        code: "40001",
        message: "MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED",
      },
    });
    const stale = await POST(request({
      action: "confirm",
      preflightId,
      expectedRevision: revision,
      requestId,
    }));
    expect(stale.status).toBe(409);
    expect(JSON.stringify(await stale.json())).not.toContain(
      "MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED",
    );
  });
});
