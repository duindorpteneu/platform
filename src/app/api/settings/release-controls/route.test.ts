import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  change: vi.fn(),
  env: vi.fn(() => ({ APP_BASE_URL: "https://tenue.example" })),
}));
vi.mock("@/lib/env", () => ({ getServerEnv: mocks.env }));
vi.mock("@/server/settings/release-controls", () => ({
  changeReleaseControl: mocks.change,
}));
import { POST } from "./route";

function request(body: unknown) {
  return new Request(
    "https://tenue.example/api/settings/release-controls",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://tenue.example",
        Host: "tenue.example",
        "Sec-Fetch-Site": "same-origin",
        "X-Duindorp-CSRF": "same-origin",
      },
      body: JSON.stringify(body),
    },
  );
}

describe("POST /api/settings/release-controls", () => {
  beforeEach(() => mocks.change.mockReset());

  it("stuurt een exacte MFA-beheerpreflight door", async () => {
    mocks.change.mockResolvedValue({ data: { base: {} }, error: null });
    const response = await POST(request({
      action: "activate",
      key: "member_seasons_v2",
      expectedRevision: "a".repeat(64),
      reason: "Staging is gereconcilieerd",
    }));
    expect(response.status).toBe(200);
    expect(mocks.change).toHaveBeenCalledWith(
      expect.objectContaining({ key: "member_seasons_v2" }),
      null,
    );
  });

  it("weigert een pauze van een onomkeerbare procespoort", async () => {
    const response = await POST(request({
      action: "pause",
      key: "allocation_qr_v2",
      expectedRevision: "a".repeat(64),
      reason: "Niet toegestaan",
    }));
    expect(response.status).toBe(400);
    expect(mocks.change).not.toHaveBeenCalled();
  });

  it("vertaalt een stale preflight naar conflict", async () => {
    mocks.change.mockResolvedValue({
      data: null,
      error: { code: "40001" },
    });
    const response = await POST(request({
      action: "activate",
      key: "package_orders_v2",
      expectedRevision: "a".repeat(64),
      reason: "Pakketten vrijgeven",
    }));
    expect(response.status).toBe(409);
  });
});
