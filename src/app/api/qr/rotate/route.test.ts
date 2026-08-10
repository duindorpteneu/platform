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

const orderId = "10000000-0000-4000-8000-000000000001";
const requestId = "20000000-0000-4000-8000-000000000001";
const correlationId = "40000000-0000-4000-8000-000000000001";
const staff = {
  userId: "30000000-0000-4000-8000-000000000001",
  role: "beheerder",
  sessionTokenHash: "a".repeat(64),
};

function request(action: "rotate" | "revoke" = "rotate") {
  return new Request("https://tenue.example/api/qr/rotate", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": correlationId,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      action,
      orderId,
      reason: "Code opnieuw uitgegeven",
      requestId,
    }),
  });
}

describe("POST /api/qr/rotate", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.QR_TOKEN_PEPPER =
      Buffer.alloc(32, 4).toString("base64url");
    process.env.QR_TOKEN_PEPPER_VERSION = "7";
    mocks.requireSession.mockReset().mockResolvedValue(staff);
    mocks.rpc.mockReset().mockImplementation((name: string) => {
      if (name === "get_order_qr_management_context_v2") {
        return Promise.resolve({
          data: {
            orderId,
            currentGeneration: 2,
            nextGeneration: 3,
            suspended: false,
            businessEligible: true,
          },
          error: null,
        });
      }
      return Promise.resolve({
        data: { orderId, generation: 3, status: "active", reused: false },
        error: null,
      });
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

  it("roteert met een verse random nonce zonder locator of nonce terug te sturen", async () => {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireSession).toHaveBeenCalledWith([
      "beheerder",
      "kledingcommissie",
    ]);
    expect(mocks.rpc).toHaveBeenNthCalledWith(
      2,
      "manage_order_qr_locator_v2",
      {
        p_action: "rotate",
        p_actor_id: staff.userId,
        p_correlation_id: correlationId,
        p_expected_generation: 2,
        p_key_version: 7,
        p_derivation_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
        p_locator_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
        p_order_id: orderId,
        p_pepper_fingerprint: expect.stringMatching(/^[a-f0-9]{64}$/),
        p_reason: "Code opnieuw uitgegeven",
        p_request_id: requestId,
        p_staff_session_hash: staff.sessionTokenHash,
      },
    );
    expect(await response.json()).toEqual({
      orderId,
      generation: 3,
      status: "active",
      reused: false,
    });
  });

  it("stuurt bij intrekken geen nieuw sleutelmateriaal", async () => {
    const response = await POST(request("revoke"));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenNthCalledWith(
      2,
      "manage_order_qr_locator_v2",
      expect.objectContaining({
        p_action: "revoke",
        p_derivation_nonce: null,
        p_key_version: null,
        p_locator_hash: null,
        p_pepper_fingerprint: null,
      }),
    );
  });

  it("vertaalt een verloren-succes payloadconflict naar 409", async () => {
    mocks.rpc.mockImplementation((name: string) => (
      name === "get_order_qr_management_context_v2"
        ? Promise.resolve({
            data: {
              orderId,
              currentGeneration: 2,
              nextGeneration: 3,
              suspended: false,
              businessEligible: true,
            },
            error: null,
          })
        : Promise.resolve({
            data: null,
            error: { code: "23505", message: "sensitive" },
          })
    ));
    const response = await POST(request());
    expect(response.status).toBe(409);
    expect(await response.text()).not.toContain("sensitive");
  });

  it("onderscheidt ongeldige context en onbekende DB-fouten", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { nextGeneration: -1 },
      error: null,
    });
    expect((await POST(request())).status).toBe(503);

    mocks.rpc.mockImplementation((name: string) => (
      name === "get_order_qr_management_context_v2"
        ? Promise.resolve({
            data: {
              orderId,
              currentGeneration: 2,
              nextGeneration: 3,
              suspended: false,
              businessEligible: true,
            },
            error: null,
          })
        : Promise.resolve({
            data: null,
            error: { code: "XX000", message: "postgres://sensitive" },
          })
    ));
    const response = await POST(request());
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("postgres");
  });

  it("blokkeert een onbevoegde sessie vóór QR-context wordt gelezen", async () => {
    mocks.requireSession.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(request());
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
