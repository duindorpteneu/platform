import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(),
  requireSession: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffSessionBinding: mocks.requireSession,
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));

import { POST } from "./route";

const requestId = "10000000-0000-4000-8000-000000000001";
const locator = `q2.k1.${"a".repeat(43)}`;
const staff = {
  userId: "20000000-0000-4000-8000-000000000001",
  role: "uitgifte",
  sessionTokenHash: "b".repeat(64),
};

function request(body: unknown, safe = true) {
  return new Request("https://tenue.example/api/fulfilment/exchange", {
    method: "POST",
    headers: safe
      ? {
          origin: "https://tenue.example",
          host: "tenue.example",
          "sec-fetch-site": "same-origin",
          "x-duindorp-csrf": "same-origin",
          "content-type": "application/json",
        }
      : { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/fulfilment/exchange", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.QR_TOKEN_PEPPER =
      Buffer.alloc(32, 4).toString("base64url");
    process.env.QR_TOKEN_PEPPER_VERSION = "1";
    mocks.requireSession.mockReset().mockResolvedValue(staff);
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        status: "found",
        grantExpiresAt: "2026-08-03T10:02:00.000Z",
        member: { firstName: "Noa", gender: "female" },
        lines: [{
          id: "30000000-0000-4000-8000-000000000001",
          article: "Shirt",
          size: "152",
          quantity: 1,
          status: "ready_for_pickup",
        }],
      },
      error: null,
    });
    mocks.admin.mockReset().mockReturnValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  afterEach(() => {
    delete process.env.APP_BASE_URL;
    delete process.env.QR_TOKEN_PEPPER;
    delete process.env.QR_TOKEN_PEPPER_VERSION;
  });

  it("wisselt een locator in via de sessiegebonden smalle RPC", async () => {
    const response = await POST(request({ locator, requestId }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireSession).toHaveBeenCalledWith([
      "beheerder",
      "uitgifte",
    ]);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "exchange_order_qr_locator_v2",
      {
        p_actor_id: staff.userId,
        p_grant_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
        p_grant_key_version: 1,
        p_locator_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
        p_request_id: requestId,
        p_staff_session_hash: staff.sessionTokenHash,
      },
    );
    const body = await response.json();
    expect(body).toMatchObject({
      status: "found",
      member: { firstName: "Noa", gender: "female" },
      scanGrant: expect.stringMatching(/^sg2\.k1\.[A-Za-z0-9_-]{43}$/),
    });
    expect(JSON.stringify(body)).not.toMatch(
      /lastName|email|dateOfBirth|relationNumber|orderId/,
    );
  });

  it("weigert een queryparameter- of niet-canonieke locator vóór de RPC", async () => {
    const response = await POST(request({
      locator: `https://tenue.example/qr?token=${locator}`,
      requestId,
    }));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ status: "invalid" });
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("behandelt een ingetrokken sleutelversie uniform als ongeldige QR", async () => {
    const response = await POST(request({
      locator: `q2.k9.${"a".repeat(43)}`,
      requestId,
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "invalid" });
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("blokkeert cross-site mutaties vóór authenticatie", async () => {
    const response = await POST(request({ locator, requestId }, false));
    expect(response.status).toBe(403);
    expect(mocks.requireSession).not.toHaveBeenCalled();
  });

  it("vertaalt ontbrekende scannerbevoegdheid naar 403", async () => {
    mocks.requireSession.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(request({ locator, requestId }));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("onderscheidt rate limiting van een operationele storing", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "P0001", message: "sensitive" },
    });
    expect((await POST(request({ locator, requestId }))).status).toBe(429);
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "XX000", message: "postgres://sensitive" },
    });
    const response = await POST(request({ locator, requestId }));
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("postgres");
  });

  it("faalt gesloten op een onverwacht databaseantwoord", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { status: "found", member: { firstName: "Noa" } },
      error: null,
    });
    const response = await POST(request({ locator, requestId }));
    expect(response.status).toBe(502);
  });
});
