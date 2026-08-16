import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  prepare: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-bootstrap", () => ({
  prepareAndActivateMailV2: mocks.prepare,
}));

import { POST } from "./route";

const correlationId = "70000000-0000-4000-8000-000000000021";

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/prepare-activate", {
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

describe("POST /api/email/v2/prepare-activate", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.prepare.mockReset().mockResolvedValue({
      data: { enabled: true, preparedCount: 17 },
      error: null,
    });
  });

  it("publiceert en activeert uitsluitend na expliciete beheerbevestiging", async () => {
    const response = await POST(request({
      action: "prepare_activate",
      reason: "Veilige systeemtemplates gecontroleerd",
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.prepare).toHaveBeenCalledWith(
      { reason: "Veilige systeemtemplates gecontroleerd" },
      correlationId,
    );
  });

  it("weigert onbekende velden en ongeldige redenen", async () => {
    const response = await POST(request({
      action: "prepare_activate",
      reason: "ja",
      bypass: true,
    }));

    expect(response.status).toBe(400);
    expect(mocks.prepare).not.toHaveBeenCalled();
  });

  it("vertaalt MFA en stale drafts zonder databasecontext te lekken", async () => {
    mocks.prepare.mockResolvedValueOnce({
      data: null,
      error: { code: "42501", message: "interne actorcontext" },
    });
    const forbidden = await POST(request({
      action: "prepare_activate",
      reason: "Templates gecontroleerd",
    }));
    expect(forbidden.status).toBe(403);
    expect(await forbidden.text()).not.toContain("interne actorcontext");

    mocks.prepare.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "interne templatehash" },
    });
    const stale = await POST(request({
      action: "prepare_activate",
      reason: "Templates gecontroleerd",
    }));
    expect(stale.status).toBe(409);
    expect(await stale.text()).not.toContain("interne templatehash");
  });
});
