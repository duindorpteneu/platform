import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ bearer: vi.fn(), admin: vi.fn(), rpc: vi.fn() }));
vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));

import { GET } from "./route";

const healthy = {
  emailJobs: { queued: 0, retry: 0, processingStale: 0, deliveryUncertain: 0, failed: 0, oldestPendingAt: null },
  operations: {
    emailWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-07-21T10:00:00.000Z", lastSucceededAt: null, stale: false, runningStale: false },
    importWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-07-21T10:00:00.000Z", lastSucceededAt: null, stale: false, runningStale: false },
    inventoryAllocator: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-07-21T09:59:00.000Z", lastSucceededAt: "2026-07-21T09:59:01.000Z", stale: false, runningStale: false },
    retention: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-07-21T09:00:00.000Z", lastSucceededAt: "2026-07-21T09:00:01.000Z", stale: false, runningStale: false },
  },
  qrControl: { cutoverActive: false, scannerActive: false, candidateOrders: 0, activeLegacyQr: 0, openGrants: 0, expiredOpenGrants: 0, keyMismatchActiveLocators: 0, keyMismatchOpenGrants: 0, previousKeyActiveLocators: 0, previousKeyOpenGrants: 0 },
  importControl: { processingEnabled: false, cutoverActive: false },
  importStaging: { pending: 0, expired: 0, oldestExpiresAt: null },
  importRuns: { queued: 0, processing: 0, processingStale: 0, failed: 0, reconciliationRequired: 0, expiredSelectedRows: 0, backlogStale: false, oldestPendingAt: null },
  recentDeliveryFailures: 0,
  reconciliationIssues: 0,
  recentWebhookFailures: 0,
  dbTime: "2026-07-21T10:00:00.000Z",
};

describe("GET /api/internal/health", () => {
  beforeEach(() => {
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    process.env.QR_TOKEN_PEPPER =
      Buffer.alloc(32, 7).toString("base64url");
    process.env.QR_TOKEN_PEPPER_VERSION = "1";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY =
      Buffer.alloc(32, 8).toString("base64url");
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.rpc.mockReset().mockResolvedValue({ data: healthy, error: null });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  afterEach(() => {
    delete process.env.QR_TOKEN_PEPPER;
    delete process.env.QR_TOKEN_PEPPER_VERSION;
    delete process.env.QR_TOKEN_PREVIOUS_PEPPER;
    delete process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION;
    delete process.env.IMPORT_STAGING_ENCRYPTION_KEY;
  });

  it.each([
    ["runtime aan en database uit", "true", false],
    ["runtime uit en database aan", "false", true],
  ])("returns HTTP 503 als de importpoorten verschillen: %s", async (
    _label,
    runtimeEnabled,
    databaseEnabled,
  ) => {
    process.env.DYNAMIC_IMPORT_ENABLED = runtimeEnabled;
    mocks.rpc.mockResolvedValueOnce({
      data: {
        ...healthy,
        importControl: {
          processingEnabled: databaseEnabled,
          cutoverActive: databaseEnabled,
        },
        operations: {
          ...healthy.operations,
          importWorker: {
            ...healthy.operations.importWorker,
            required: databaseEnabled,
          },
        },
      },
      error: null,
    });
    const response = await GET(new Request("https://tenue.example/api/internal/health"));
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      status: "degraded",
      importGateMatches: false,
    });
  });

  it("returns HTTP 200 only for an operationally healthy state", async () => {
    const response = await GET(new Request("https://tenue.example/api/internal/health"));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_operational_health_v7",
      {
        p_current_key_version: 1,
        p_current_pepper_fingerprint:
          expect.stringMatching(/^[a-f0-9]{64}$/),
        p_previous_key_version: null,
        p_previous_pepper_fingerprint: null,
      },
    );
    expect(await response.json()).toMatchObject({ status: "healthy" });
  });

  it("geeft de gecontroleerde vorige QR-sleutel aan health door", async () => {
    process.env.QR_TOKEN_PREVIOUS_PEPPER =
      Buffer.alloc(32, 6).toString("base64url");
    process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION = "2";
    process.env.QR_TOKEN_PEPPER_VERSION = "3";
    const response = await GET(
      new Request("https://tenue.example/api/internal/health"),
    );
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_operational_health_v7",
      {
        p_current_key_version: 3,
        p_current_pepper_fingerprint:
          expect.stringMatching(/^[a-f0-9]{64}$/),
        p_previous_key_version: 2,
        p_previous_pepper_fingerprint:
          expect.stringMatching(/^[a-f0-9]{64}$/),
      },
    );
  });

  it.each([
    ["uncertain delivery", { emailJobs: { ...healthy.emailJobs, deliveryUncertain: 1 } }],
    ["missed worker", { operations: { ...healthy.operations, emailWorker: { ...healthy.operations.emailWorker, required: true, stale: true } } }],
    ["delivery failure", { recentDeliveryFailures: 1 }],
    ["expired import staging", { importStaging: { pending: 0, expired: 1, oldestExpiresAt: null } }],
    ["stale import", { importRuns: { ...healthy.importRuns, processingStale: 1 } }],
    ["import reconciliation", { importRuns: { ...healthy.importRuns, reconciliationRequired: 1 } }],
    ["stale import backlog", { importRuns: { ...healthy.importRuns, backlogStale: true } }],
  ])("returns HTTP 503 for %s", async (_label, patch) => {
    mocks.rpc.mockResolvedValueOnce({ data: { ...healthy, ...patch }, error: null });
    const response = await GET(new Request("https://tenue.example/api/internal/health"));
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });

  it("redigeert een onverwachte database- of netwerkfout naar 503", async () => {
    mocks.rpc.mockRejectedValueOnce(new Error("postgres://sensitive"));
    const response = await GET(new Request("https://tenue.example/api/internal/health"));
    expect(response.status).toBe(503);
    const body = JSON.stringify(await response.json());
    expect(body).toContain("health_query_failed");
    expect(body).not.toContain("postgres");
  });
});
