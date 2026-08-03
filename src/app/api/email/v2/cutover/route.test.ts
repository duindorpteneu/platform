import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  change: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-workspace", () => ({
  changeMailV2Cutover: mocks.change,
}));

import { POST } from "./route";

const revision = "c".repeat(64);
const correlationId = "70000000-0000-4000-8000-000000000001";
const snapshot = {
  enabled: true,
  cutoverAt: "2026-08-03T10:00:00.000Z",
  catalogCount: 19,
  publishedCount: 19,
  brandingCount: 1,
  producerCount: 19,
  ready: true,
  revision,
  reused: false,
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/cutover", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": correlationId,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/email/v2/cutover", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.change.mockReset().mockResolvedValue({
      data: snapshot,
      error: null,
    });
  });

  it("activeert alleen met een getypeerde revisie en geaudite reden", async () => {
    const input = {
      action: "activate",
      expectedRevision: revision,
      reason: "Volledige catalogus handmatig gecontroleerd",
    } as const;
    const response = await POST(request(input));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.change).toHaveBeenCalledWith(input, correlationId);
  });

  it("weigert onbekende velden en controletekens vóór databaseautorisatie", async () => {
    const response = await POST(request({
      action: "pause",
      reason: "Incident\r\nBcc: test@example.invalid",
      enabled: false,
    }));

    expect(response.status).toBe(400);
    expect(mocks.change).not.toHaveBeenCalled();
  });

  it("vertaalt stale preflight en reconciliatie zonder SQL-context te lekken", async () => {
    mocks.change.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "interne templatehash" },
    });
    const stale = await POST(request({
      action: "activate",
      expectedRevision: revision,
      reason: "Catalogus gecontroleerd",
    }));
    expect(stale.status).toBe(409);
    expect(await stale.text()).not.toContain("interne templatehash");

    mocks.change.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "interne cataloguscontext" },
    });
    const blocked = await POST(request({
      action: "activate",
      expectedRevision: revision,
      reason: "Catalogus gecontroleerd",
    }));
    expect(blocked.status).toBe(422);
    expect(await blocked.text()).not.toContain("interne cataloguscontext");
  });
});
