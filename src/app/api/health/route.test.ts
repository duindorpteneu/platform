import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn() }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
import { GET } from "./route";

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
    process.env.CRON_SECRET = "c".repeat(16);
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
    delete process.env.CRON_SECRET;
  });

  it("returns a minimal release-aware JSON readiness response", async () => {
    mocks.admin.mockReturnValue({ schema: () => ({ rpc: vi.fn().mockResolvedValue({ data: { emailJobs: { queued: 0, retry: 0, processingStale: 0, failed: 0 }, reconciliationIssues: 0, recentWebhookFailures: 0, dbTime: "2026-07-19T12:00:00.000Z" }, error: null }) }) });
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

  it("returns a redacted 503 when readiness throws", async () => {
    mocks.admin.mockImplementation(() => { throw new Error("postgres://secret"); });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("postgres");
  });
});
