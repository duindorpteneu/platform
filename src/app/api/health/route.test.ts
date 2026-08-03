import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn() }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
import { GET } from "./route";

const healthyOperationalState = {
  emailJobs: { queued: 0, retry: 0, processingStale: 0, deliveryUncertain: 0, failed: 0, oldestPendingAt: null },
  operations: {
    emailWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: null, stale: false, runningStale: false },
    importWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: null, stale: false, runningStale: false },
    inventoryAllocator: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: "2026-08-03T08:00:01.000Z", stale: false, runningStale: false },
    retention: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: "2026-08-03T08:00:01.000Z", stale: false, runningStale: false },
  },
  qrControl: { cutoverActive: false, scannerActive: false, candidateOrders: 0, activeLegacyQr: 0, openGrants: 0, expiredOpenGrants: 0, keyMismatchActiveLocators: 0, keyMismatchOpenGrants: 0, previousKeyActiveLocators: 0, previousKeyOpenGrants: 0 },
  importControl: { processingEnabled: false, cutoverActive: false },
  importStaging: { pending: 0, expired: 0, oldestExpiresAt: null },
  importRuns: { queued: 0, processing: 0, processingStale: 0, failed: 0, reconciliationRequired: 0, expiredSelectedRows: 0, backlogStale: false, oldestPendingAt: null },
  recentDeliveryFailures: 0,
  reconciliationIssues: 0,
  recentWebhookFailures: 0,
  dbTime: "2026-08-03T08:00:00.000Z",
};

describe("GET /api/health", () => {
  beforeEach(() => {
    process.env.APP_ENVIRONMENT = "staging";
    process.env.RELEASE_SHA = "a".repeat(40);
    process.env.APP_BASE_URL = "https://staging-duindorp.dgwebservices.nl";
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://abcdefghijklmnopqrst.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "anon-key".repeat(8);
    process.env.SUPABASE_SECRET_KEY = "service-key".repeat(8);
    process.env.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY = "e".repeat(44);
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    process.env.QR_TOKEN_PEPPER =
      Buffer.alloc(32, 7).toString("base64url");
    process.env.QR_TOKEN_PEPPER_VERSION = "1";
    process.env.CRON_SECRET = "c".repeat(16);
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    process.env.IMPORT_RAW_RETENTION_HOURS = "24";
    delete process.env.IMPORT_STAGING_ENCRYPTION_KEY;
    mocks.admin.mockReset();
  });
  afterEach(() => {
    delete process.env.APP_ENVIRONMENT;
    delete process.env.RELEASE_SHA;
    delete process.env.APP_BASE_URL;
    delete process.env.NEXT_PUBLIC_SUPABASE_URL;
    delete process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
    delete process.env.SUPABASE_SECRET_KEY;
    delete process.env.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY;
    delete process.env.PARENT_TOKEN_PEPPER;
    delete process.env.QR_TOKEN_PEPPER;
    delete process.env.QR_TOKEN_PEPPER_VERSION;
    delete process.env.QR_TOKEN_PREVIOUS_PEPPER;
    delete process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION;
    delete process.env.CRON_SECRET;
    delete process.env.DYNAMIC_IMPORT_ENABLED;
    delete process.env.IMPORT_RAW_RETENTION_HOURS;
    delete process.env.IMPORT_STAGING_ENCRYPTION_KEY;
  });

  it("returns a minimal release-aware JSON readiness response", async () => {
    mocks.admin.mockReturnValue({ schema: () => ({ rpc: vi.fn().mockResolvedValue({ data: {
      emailJobs: { queued: 0, retry: 0, processingStale: 0, deliveryUncertain: 0, failed: 0, oldestPendingAt: null },
      operations: {
        emailWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-07-19T11:59:00.000Z", lastSucceededAt: null, stale: false, runningStale: false },
        importWorker: { required: false, lastStatus: "paused", lastStartedAt: "2026-07-19T11:59:30.000Z", lastSucceededAt: null, stale: false, runningStale: false },
        inventoryAllocator: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-07-19T11:59:30.000Z", lastSucceededAt: "2026-07-19T11:59:31.000Z", stale: false, runningStale: false },
        retention: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-07-19T11:00:00.000Z", lastSucceededAt: "2026-07-19T11:00:01.000Z", stale: false, runningStale: false },
      },
      qrControl: { cutoverActive: false, scannerActive: false, candidateOrders: 0, activeLegacyQr: 0, openGrants: 0, expiredOpenGrants: 0, keyMismatchActiveLocators: 0, keyMismatchOpenGrants: 0, previousKeyActiveLocators: 0, previousKeyOpenGrants: 0 },
      importControl: { processingEnabled: false, cutoverActive: false },
      importStaging: { pending: 0, expired: 0, oldestExpiresAt: null },
      importRuns: { queued: 0, processing: 0, processingStale: 0, failed: 0, reconciliationRequired: 0, expiredSelectedRows: 0, backlogStale: false, oldestPendingAt: null },
      recentDeliveryFailures: 0,
      reconciliationIssues: 0,
      recentWebhookFailures: 0,
      dbTime: "2026-07-19T12:00:00.000Z",
    }, error: null }) }) });
    const response = await GET();
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("application/json");
    expect(await response.json()).toEqual({ status: "ok", service: "duindorpteneu", environment: "staging", revision: "a".repeat(40) });
  });

  it("returns 503 without valid critical release configuration", async () => {
    delete process.env.RELEASE_SHA;
    const response = await GET();
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toMatch(/supabase|postgres|secret/i);
  });

  it("weigert een half geconfigureerde vorige QR-sleutel", async () => {
    process.env.QR_TOKEN_PREVIOUS_PEPPER =
      Buffer.alloc(32, 6).toString("base64url");
    const response = await GET();
    expect(response.status).toBe(503);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each([
    ["locator", { keyMismatchActiveLocators: 1 }],
    ["open grant", { keyMismatchOpenGrants: 1 }],
  ])("blokkeert deploy-readiness bij een QR-keymismatch voor %s", async (
    _label,
    qrPatch,
  ) => {
    mocks.admin.mockReturnValue({
      schema: () => ({
        rpc: vi.fn().mockResolvedValue({
          data: {
            ...healthyOperationalState,
            qrControl: {
              ...healthyOperationalState.qrControl,
              ...qrPatch,
            },
          },
          error: null,
        }),
      }),
    });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });

  it("blokkeert deploy-readiness bij een gequarantaineerd provider-event", async () => {
    mocks.admin.mockReturnValue({
      schema: () => ({
        rpc: vi.fn().mockResolvedValue({
          data: {
            ...healthyOperationalState,
            emailDeliveryAttempts: {
              legacyAmbiguous: 0,
              quarantinedEvents: 1,
              unboundLegacyEvents: 0,
              processingWithoutCurrentAttempt: 0,
            },
          },
          error: null,
        }),
      }),
    });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });

  it("blokkeert deploy-readiness bij een recente herinneringsplannerfout", async () => {
    mocks.admin.mockReturnValue({
      schema: () => ({
        rpc: vi.fn().mockResolvedValue({
          data: {
            ...healthyOperationalState,
            reminderPlanner: {
              activeRules: 1,
              failedRunsRecent: 1,
              activeRulesNeverRun: 0,
              lastCompletedAt: "2026-08-03T08:00:00.000Z",
            },
          },
          error: null,
        }),
      }),
    });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });

  it("blokkeert deploy-readiness bij een onzekere OTP-aflevering", async () => {
    mocks.admin.mockReturnValue({
      schema: () => ({
        rpc: vi.fn().mockResolvedValue({
          data: {
            ...healthyOperationalState,
            parentOtpDelivery: {
              stalePrepared: 0,
              deliveryUncertainRecent: 1,
              sendFailuresRecent: 0,
              quarantinedEvents: 0,
              providerFailuresRecent: 0,
            },
          },
          error: null,
        }),
      }),
    });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });

  it("houdt publieke liveness beschikbaar bij een zachte operationele storing", async () => {
    mocks.admin.mockReturnValue({
      schema: () => ({
        rpc: vi.fn().mockResolvedValue({
          data: {
            emailJobs: { queued: 0, retry: 0, processingStale: 0, deliveryUncertain: 0, failed: 0, oldestPendingAt: null },
            operations: {
              emailWorker: { required: false, lastStatus: "paused", lastStartedAt: null, lastSucceededAt: null, stale: false, runningStale: false },
              importWorker: { required: false, lastStatus: "failed", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: null, stale: true, runningStale: false },
              inventoryAllocator: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: "2026-08-03T08:00:01.000Z", stale: false, runningStale: false },
              retention: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: "2026-08-03T08:00:01.000Z", stale: false, runningStale: false },
            },
            qrControl: { cutoverActive: false, scannerActive: false, candidateOrders: 0, activeLegacyQr: 0, openGrants: 0, expiredOpenGrants: 0, keyMismatchActiveLocators: 0, keyMismatchOpenGrants: 0, previousKeyActiveLocators: 0, previousKeyOpenGrants: 0 },
            importControl: { processingEnabled: false, cutoverActive: true },
            importStaging: { pending: 0, expired: 0, oldestExpiresAt: null },
            importRuns: { queued: 0, processing: 0, processingStale: 0, failed: 0, reconciliationRequired: 1, expiredSelectedRows: 0, backlogStale: false, oldestPendingAt: null },
            recentDeliveryFailures: 0,
            reconciliationIssues: 0,
            recentWebhookFailures: 0,
            dbTime: "2026-08-03T08:00:00.000Z",
          },
          error: null,
        }),
      }),
    });
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "ok" });
  });

  it("vereist een canonieke importkey zodra runtime-import actief is", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    const response = await GET();
    expect(response.status).toBe(503);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("weigert readiness wanneer runtime en database-importpoort verschillen", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = Buffer.alloc(32, 1).toString("base64url");
    mocks.admin.mockReturnValue({
      schema: () => ({
        rpc: vi.fn().mockResolvedValue({
          data: {
            emailJobs: { queued: 0, retry: 0, processingStale: 0, deliveryUncertain: 0, failed: 0, oldestPendingAt: null },
            operations: {
              emailWorker: { required: false, lastStatus: "paused", lastStartedAt: null, lastSucceededAt: null, stale: false, runningStale: false },
              importWorker: { required: false, lastStatus: "paused", lastStartedAt: null, lastSucceededAt: null, stale: false, runningStale: false },
              inventoryAllocator: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: "2026-08-03T08:00:01.000Z", stale: false, runningStale: false },
              retention: { required: true, lastStatus: "succeeded", lastStartedAt: "2026-08-03T08:00:00.000Z", lastSucceededAt: "2026-08-03T08:00:01.000Z", stale: false, runningStale: false },
            },
            qrControl: { cutoverActive: false, scannerActive: false, candidateOrders: 0, activeLegacyQr: 0, openGrants: 0, expiredOpenGrants: 0, keyMismatchActiveLocators: 0, keyMismatchOpenGrants: 0, previousKeyActiveLocators: 0, previousKeyOpenGrants: 0 },
            importControl: { processingEnabled: false, cutoverActive: true },
            importStaging: { pending: 0, expired: 0, oldestExpiresAt: null },
            importRuns: { queued: 0, processing: 0, processingStale: 0, failed: 0, reconciliationRequired: 0, expiredSelectedRows: 0, backlogStale: false, oldestPendingAt: null },
            recentDeliveryFailures: 0,
            reconciliationIssues: 0,
            recentWebhookFailures: 0,
            dbTime: "2026-08-03T08:00:00.000Z",
          },
          error: null,
        }),
      }),
    });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded" });
  });

  it("returns a redacted 503 when readiness throws", async () => {
    mocks.admin.mockImplementation(() => { throw new Error("postgres://secret"); });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("postgres");
  });
});
