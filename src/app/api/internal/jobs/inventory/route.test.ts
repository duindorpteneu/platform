import { beforeEach, describe, expect, it, vi } from "vitest";

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
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.startRun.mockReset().mockResolvedValue(true);
    mocks.finishRun.mockReset().mockResolvedValue(true);
    mocks.rpc.mockReset().mockResolvedValue({
      data: { processed: 3, failed: 0, disabled: false },
      error: null,
    });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
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
    await expect(response.json()).resolves.toMatchObject({ status: "succeeded", processed: 3, failed: 0 });
    expect(mocks.rpc).toHaveBeenCalledWith("process_inventory_allocation_queue", { p_limit: 50 });
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

  it("fails closed on an invalid database result", async () => {
    mocks.rpc.mockResolvedValue({ data: { processed: -1 }, error: null });
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
});
