import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ bearer: vi.fn(), admin: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));

import { GET } from "./route";

const healthy = {
  emailJobs: { queued: 0, retry: 0, processingStale: 0, deliveryUncertain: 0, failed: 0, oldestPendingAt: null },
  operations: {
    emailWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-07-21T10:00:00.000Z", lastSucceededAt: null, stale: false, runningStale: false },
    retention: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-07-21T09:00:00.000Z", lastSucceededAt: "2026-07-21T09:00:01.000Z", stale: false, runningStale: false },
  },
  importStaging: { pending: 0, expired: 0, oldestExpiresAt: null },
  recentDeliveryFailures: 0,
  reconciliationIssues: 0,
  recentWebhookFailures: 0,
  dbTime: "2026-07-21T10:00:00.000Z",
};

describe("GET /api/internal/health", () => {
  beforeEach(() => {
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.rpc.mockReset().mockResolvedValue({ data: healthy, error: null });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("returns HTTP 200 only for an operationally healthy state", async () => {
    const response = await GET(new Request("https://tenue.example/api/internal/health"));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("get_operational_health_v3");
    expect(await response.json()).toMatchObject({ status: "healthy" });
  });

  it.each([
    ["uncertain delivery", { emailJobs: { ...healthy.emailJobs, deliveryUncertain: 1 } }],
    ["missed worker", { operations: { ...healthy.operations, emailWorker: { ...healthy.operations.emailWorker, required: true, stale: true } } }],
    ["delivery failure", { recentDeliveryFailures: 1 }],
    ["expired import staging", { importStaging: { pending: 0, expired: 1, oldestExpiresAt: null } }],
  ])("returns HTTP 503 for %s", async (_label, patch) => {
    mocks.rpc.mockResolvedValueOnce({ data: { ...healthy, ...patch }, error: null });
    const response = await GET(new Request("https://tenue.example/api/internal/health"));
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });
});
