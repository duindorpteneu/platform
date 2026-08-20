import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  bearer: vi.fn(),
  admin: vi.fn(),
  rpc: vi.fn(),
  startRun: vi.fn(),
  finishRun: vi.fn(),
}));

vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/operations/run-ledger", () => ({
  startOperationRun: mocks.startRun,
  finishOperationRun: mocks.finishRun,
}));

import { POST } from "./route";

describe("POST /api/internal/jobs/inventory", () => {
  beforeEach(() => {
    process.env.QR_TOKEN_PEPPER =
      Buffer.alloc(32, 4).toString("base64url");
    process.env.QR_TOKEN_PEPPER_VERSION = "3";
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.startRun.mockReset().mockResolvedValue(true);
    mocks.finishRun.mockReset().mockResolvedValue(true);
    mocks.rpc.mockReset().mockImplementation((name: string) => {
      if (name === "expire_qr_scan_grants") {
        return Promise.resolve({
          data: { expired: 0 },
          error: null,
        });
      }
      if (name === "process_inventory_allocation_queue") {
        return Promise.resolve({
          data: {
            processed: 3,
            completed: 2,
            retryable: 1,
            exhausted: 0,
            failed: 0,
            disabled: false,
          },
          error: null,
        });
      }
      if (name === "list_order_qr_identity_candidates") {
        return Promise.resolve({
          data: { candidates: [] },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { message: "unexpected" } });
    });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  afterEach(() => {
    delete process.env.QR_TOKEN_PEPPER;
    delete process.env.QR_TOKEN_PEPPER_VERSION;
  });

  it("rejects a missing or invalid internal bearer", async () => {
    mocks.bearer.mockReturnValue(false);
    const response = await POST(new Request("https://portal.test/api/internal/jobs/inventory", { method: "POST" }));
    expect(response.status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("processes the bounded allocation queue and records monitoring", async () => {
    const response = await POST(new Request("https://portal.test/api/internal/jobs/inventory", { method: "POST" }));
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      status: "succeeded",
      processed: 3,
      completed: 2,
      retryable: 1,
      exhausted: 0,
      failed: 0,
    });
    expect(mocks.rpc).toHaveBeenCalledWith("process_inventory_allocation_queue", { p_limit: 50 });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "expire_qr_scan_grants",
      { p_limit: 500 },
    );
    expect(mocks.rpc).toHaveBeenCalledWith(
      "list_order_qr_identity_candidates",
      { p_limit: 10 },
    );
    expect(mocks.startRun).toHaveBeenCalledWith(expect.anything(), "inventory_allocator", expect.any(String));
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "inventory_allocator",
      expect.any(String),
      "succeeded",
      3,
      null,
    );
  });

  it("reports terminal queue exhaustion without failing scheduler liveness", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "expire_qr_scan_grants") {
        return Promise.resolve({ data: { expired: 0 }, error: null });
      }
      if (name === "process_inventory_allocation_queue") {
        return Promise.resolve({
          data: {
            processed: 1,
            completed: 0,
            retryable: 0,
            exhausted: 1,
            failed: 0,
            disabled: false,
          },
          error: null,
        });
      }
      if (name === "list_order_qr_identity_candidates") {
        return Promise.resolve({ data: { candidates: [] }, error: null });
      }
      return Promise.resolve({ data: null, error: { message: "unexpected" } });
    });

    const response = await POST(new Request(
      "https://portal.test/api/internal/jobs/inventory",
      { method: "POST" },
    ));

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      status: "succeeded",
      exhausted: 1,
      failed: 0,
    });
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "inventory_allocator",
      expect.any(String),
      "succeeded",
      1,
      null,
    );
  });

  it("fails closed on an invalid database result", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "expire_qr_scan_grants") {
        return Promise.resolve({ data: { expired: 0 }, error: null });
      }
      return Promise.resolve({ data: { processed: -1 }, error: null });
    });
    const response = await POST(new Request("https://portal.test/api/internal/jobs/inventory", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "inventory_allocator",
      expect.any(String),
      "failed",
      0,
      "allocation_queue_failed",
    );
  });

  it("provisiont kandidaten begrensd met een random nonce en gehashte locator", async () => {
    const orderId = "10000000-0000-4000-8000-000000000001";
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "expire_qr_scan_grants") {
        return Promise.resolve({ data: { expired: 0 }, error: null });
      }
      if (name === "process_inventory_allocation_queue") {
        return Promise.resolve({
          data: {
            processed: 0,
            completed: 0,
            retryable: 0,
            exhausted: 0,
            failed: 0,
            disabled: false,
          },
          error: null,
        });
      }
      if (name === "list_order_qr_identity_candidates") {
        return Promise.resolve({
          data: {
            candidates: [{
              orderId,
              generation: 4,
              hasActiveLegacy: true,
            }],
          },
          error: null,
        });
      }
      if (name === "register_order_qr_locator") {
        return Promise.resolve({ data: { status: "active" }, error: null });
      }
      return Promise.resolve({ data: null, error: { message: "unexpected" } });
    });
    const response = await POST(new Request(
      "https://portal.test/api/internal/jobs/inventory",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      qrProvisioned: 1,
      status: "succeeded",
    });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "register_order_qr_locator",
      {
        p_derivation_nonce:
          expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
        p_generation: 4,
        p_key_version: 3,
        p_locator_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
        p_order_id: orderId,
        p_pepper_fingerprint:
          expect.stringMatching(/^[a-f0-9]{64}$/),
        p_request_id: expect.stringMatching(
          /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        ),
      },
    );
  });
});
