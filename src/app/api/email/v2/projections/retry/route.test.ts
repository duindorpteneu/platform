import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  retry: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-workspace", () => ({
  retryMailV2Projection: mocks.retry,
}));

import { POST } from "./route";

const groupId = "73000000-0000-4000-8000-000000000001";
const correlationId = "73000000-0000-4000-8000-000000000002";

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/projections/retry", {
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

describe("POST /api/email/v2/projections/retry", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.retry.mockReset().mockResolvedValue({
      data: { groupId, status: "leased", retryCount: 1 },
      error: null,
    });
  });

  it("vraagt een begrensde geaudite herprojectie aan", async () => {
    const input = {
      groupId,
      expectedRetryCount: 0,
      reason: "Template gecorrigeerd en opnieuw gecontroleerd",
    };
    const response = await POST(request(input));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.retry).toHaveBeenCalledWith(input, correlationId);
  });

  it("weigert onbekende velden en controletekens", async () => {
    const response = await POST(request({
      groupId,
      expectedRetryCount: 0,
      reason: "Herstel\r\nBcc: test@example.invalid",
      force: true,
    }));

    expect(response.status).toBe(400);
    expect(mocks.retry).not.toHaveBeenCalled();
  });

  it("vertaalt stale en niet-herstelbare projecties zonder SQL-context", async () => {
    mocks.retry.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "MAIL_V2_PROJECTION_RETRY_STALE" },
    });
    const stale = await POST(request({
      groupId,
      expectedRetryCount: 0,
      reason: "Opnieuw gecontroleerd",
    }));
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({
      error: "De projectie is intussen gewijzigd. Vernieuw de preflight.",
    });

    mocks.retry.mockResolvedValueOnce({
      data: null,
      error: { code: "55000", message: "internal detail" },
    });
    const blocked = await POST(request({
      groupId,
      expectedRetryCount: 0,
      reason: "Opnieuw gecontroleerd",
    }));
    expect(blocked.status).toBe(409);
    expect(JSON.stringify(await blocked.json())).not.toContain(
      "internal detail",
    );
  });
});
