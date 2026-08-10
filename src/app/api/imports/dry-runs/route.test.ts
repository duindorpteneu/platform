import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireStaffRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));

import { GET, POST } from "./route";

const batchId = "10000000-0000-4000-8000-000000000001";
const runId = "20000000-0000-4000-8000-000000000001";
const clientRequestId = "30000000-0000-4000-8000-000000000001";

function mutation(body: unknown) {
  return new Request("https://tenue.example/api/imports/dry-runs", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("/api/imports/dry-runs", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = Buffer.alloc(32, 1).toString("base64url");
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      userId: "40000000-0000-4000-8000-000000000001",
      role: "beheerder",
    });
    mocks.rpc.mockReset();
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("queueert een idempotente actor- en mappinggebonden dry-run", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { runId, batchId, status: "queued_preview", reused: false },
      error: null,
    });
    const response = await POST(mutation({
      batchId,
      mappingRevision: 2,
      clientRequestId,
    }));
    expect(response.status).toBe(202);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "begin_dynamic_import_dry_run",
      expect.objectContaining({
        p_batch_id: batchId,
        p_mapping_revision: 2,
        p_client_request_id: clientRequestId,
        p_request_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
      }),
    );
  });

  it("leest uitsluitend veilige, gepagineerde rijresultaten", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        runId,
        batchId,
        seasonId: "50000000-0000-4000-8000-000000000001",
        status: "previewed",
        sourceRowCount: 1,
        processedRowCount: 1,
        committedRowCount: 0,
        outcomeCounts: { create: 1, update: 0, skip: 0, protected: 0, conflict: 0, error: 0 },
        hasBlockers: false,
        planHash: "a".repeat(64),
        expiresAt: "2026-08-04T10:00:00.000Z",
        previewedAt: "2026-08-03T10:00:00.000Z",
        committedAt: null,
        failureCode: null,
        offset: 0,
        limit: 100,
        filteredTotal: 1,
        rows: [{
          sourceRow: 2,
          outcome: "create",
          blocking: false,
          reasonCodes: [],
          changeCount: 2,
          conflictCount: 0,
          protectedCount: 0,
        }],
      },
      error: null,
    });
    const response = await GET(new Request(
      `https://tenue.example/api/imports/dry-runs?runId=${runId}&limit=100`,
    ));
    expect(response.status).toBe(200);
    expect(JSON.stringify(await response.json())).not.toMatch(/name|email|dateOfBirth/i);
    expect(mocks.rpc).toHaveBeenCalledWith("get_dynamic_import_dry_run", {
      p_run_id: runId,
      p_outcome: null,
      p_offset: 0,
      p_limit: 100,
    });
  });

  it("weigert start wanneer de onafhankelijke runtimepoort dicht staat", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    const response = await POST(mutation({
      batchId,
      mappingRevision: 2,
      clientRequestId,
    }));
    expect(response.status).toBe(503);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it.each([
    [`runId=${runId}&offset=10001`, "te grote offset"],
    [`runId=${runId}&offset=-1`, "negatieve offset"],
    [`runId=${runId}&limit=101`, "te grote limiet"],
    [`runId=${runId}&outcome=unknown`, "onbekende uitkomst"],
  ])("weigert een ongeldige query: %s (%s)", async (query) => {
    const response = await GET(new Request(
      `https://tenue.example/api/imports/dry-runs?${query}`,
    ));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("weigert een ongeldige mutatie vóór databasegebruik", async () => {
    const response = await POST(mutation({
      batchId,
      mappingRevision: 0,
      clientRequestId,
    }));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["42501", "", 403],
    ["P0002", "", 404],
    ["40001", "DYNAMIC_IMPORT_CATALOG_CHANGED", 409],
    ["23505", "", 409],
  ])("vertaalt RPC-fout %s naar HTTP %s", async (
    code,
    message,
    expectedStatus,
  ) => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code, message },
    });
    const response = await POST(mutation({
      batchId,
      mappingRevision: 2,
      clientRequestId,
    }));
    expect(response.status).toBe(expectedStatus);
    expect(response.headers.get("cache-control")).toContain("no-store");
  });
});
