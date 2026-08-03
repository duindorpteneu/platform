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
    mocks.rpc.mockReset().mockImplementation(async (name: string) => (
      name === "purge_mail_v2_campaign_preflights_v1"
        ? { data: 10, error: null }
        : {
          data: {
            otpChallenges: 1,
            rateLimitEvents: 2,
            parentSessions: 3,
            emailEvents: 4,
            importStaging: 5,
            importSelectedRows: 6,
            importRunsExpired: 7,
            importPartialFailures: 8,
            importPlansPurged: 9,
          },
          error: null,
        }
    ));
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("records the monitored run and only aggregate deletion counts", async () => {
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(200);
    expect(mocks.finishRun).toHaveBeenCalledWith(expect.anything(), "retention", expect.any(String), "succeeded", 55);
    expect(mocks.rpc).toHaveBeenCalledWith("cleanup_expired_security_data_v3", { p_now: expect.any(String) });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "purge_mail_v2_campaign_preflights_v1",
      {
        p_now: expect.any(String),
        p_retention_hours: 24,
        p_limit: 500,
      },
    );
    expect(await response.json()).toEqual({
      status: "completed",
      deleted: {
        otpChallenges: 1,
        rateLimitEvents: 2,
        parentSessions: 3,
        emailEvents: 4,
        importStaging: 5,
        importSelectedRows: 6,
        importRunsExpired: 7,
        importPartialFailures: 8,
        importPlansPurged: 9,
        campaignPreflights: 10,
      },
    });
  });

  it("records a stable non-PII failure code", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "XX000" } });
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenCalledWith(expect.anything(), "retention", expect.any(String), "failed", 0, "cleanup_failed");
  });

  it("faalt gemonitord als campagnepreflightretentie niet kan draaien", async () => {
    mocks.rpc.mockImplementation(async (name: string) => (
      name === "purge_mail_v2_campaign_preflights_v1"
        ? { data: null, error: { code: "XX000" } }
        : {
          data: {
            otpChallenges: 1,
            rateLimitEvents: 2,
            parentSessions: 3,
            emailEvents: 4,
            importStaging: 5,
            importSelectedRows: 6,
            importRunsExpired: 7,
            importPartialFailures: 8,
            importPlansPurged: 9,
          },
          error: null,
        }
    ));
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "retention",
      expect.any(String),
      "failed",
      0,
      "campaign_cleanup_failed",
    );
  });

  it("sluit een gestarte run gecontroleerd na een onverwachte RPC-fout", async () => {
    mocks.rpc.mockRejectedValueOnce(new Error("database details die niet mogen lekken"));
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "Retentiejob kon niet veilig worden uitgevoerd.",
    });
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "retention",
      expect.any(String),
      "failed",
      0,
      "cleanup_failed",
    );
  });

  it("lekt geen afsluitfout wanneer monitoring zelf tijdelijk faalt", async () => {
    mocks.rpc.mockRejectedValueOnce(new Error("provider secret"));
    mocks.finishRun.mockRejectedValueOnce(new Error("monitoring secret"));
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/retention", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("secret");
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
