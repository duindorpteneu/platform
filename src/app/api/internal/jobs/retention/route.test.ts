import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ bearer: vi.fn(), admin: vi.fn(), rpc: vi.fn(), startRun: vi.fn(), finishRun: vi.fn() }));
vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/operations/run-ledger", () => ({ startOperationRun: mocks.startRun, finishOperationRun: mocks.finishRun }));

import { POST } from "./route";

describe("POST /api/internal/jobs/retention", () => {
  beforeEach(() => {
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.startRun.mockReset().mockResolvedValue(true);
    mocks.finishRun.mockReset().mockResolvedValue(true);
    mocks.rpc.mockReset().mockResolvedValue({
      data: { otpChallenges: 1, rateLimitEvents: 2, parentSessions: 3, emailEvents: 4, importStaging: 5 },
      error: null,
    });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("records the monitored run and only aggregate deletion counts", async () => {
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(200);
    expect(mocks.finishRun).toHaveBeenCalledWith(expect.anything(), "retention", expect.any(String), "succeeded", 15);
    expect(mocks.rpc).toHaveBeenCalledWith("cleanup_expired_security_data_v2", { p_now: expect.any(String) });
    expect(await response.json()).toEqual({
      status: "completed",
      deleted: { otpChallenges: 1, rateLimitEvents: 2, parentSessions: 3, emailEvents: 4, importStaging: 5 },
    });
  });

  it("records a stable non-PII failure code", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "XX000" } });
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenCalledWith(expect.anything(), "retention", expect.any(String), "failed", 0, "cleanup_failed");
  });

  it("weigert een body voordat de retentiejob start", async () => {
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", {
      method: "POST",
      body: "unexpected",
    }));
    expect(response.status).toBe(413);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.startRun).not.toHaveBeenCalled();
  });
});
