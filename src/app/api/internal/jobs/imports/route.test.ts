import { beforeEach, describe, expect, it, vi } from "vitest";
import { IMPORT_POLICY } from "@/lib/import-contract";

const mocks = vi.hoisted(() => ({
  bearer: vi.fn(),
  admin: vi.fn(),
  rpc: vi.fn(),
  startRun: vi.fn(),
  finishRun: vi.fn(),
  env: vi.fn(),
  readPayload: vi.fn(),
  openCsv: vi.fn(),
  headerHash: vi.fn(),
  selectedRows: vi.fn(),
}));
vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/operations/run-ledger", () => ({
  startOperationRun: mocks.startRun,
  finishOperationRun: mocks.finishRun,
}));
vi.mock("@/lib/env", () => ({ getServerEnv: mocks.env }));
vi.mock("@/server/imports/workspace", () => ({ readStagedImportPayload: mocks.readPayload }));
vi.mock("@/server/imports/mapping", () => ({
  openStagedCsv: mocks.openCsv,
  importHeaderHash: mocks.headerHash,
}));
vi.mock("@/server/imports/selected-rows", () => ({
  buildSelectedImportRows: mocks.selectedRows,
}));

import { POST } from "./route";

const jobBase = {
  runId: "10000000-0000-4000-8000-000000000001",
  batchId: "20000000-0000-4000-8000-000000000001",
  actorId: "30000000-0000-4000-8000-000000000001",
  seasonId: "40000000-0000-4000-8000-000000000001",
  mappingRevisionId: "50000000-0000-4000-8000-000000000001",
  mappingRevision: 1,
  mapping: [{
    columnIndex: 0,
    sourceHeaderHash: "a".repeat(64),
    target: { kind: "member_field", field: "external_member_id" },
  }],
  mappingHash: "b".repeat(64),
  headerHash: "c".repeat(64),
  catalogHash: "d".repeat(64),
  catalogCurrent: true,
  policy: IMPORT_POLICY,
  generation: 1,
  nextSourceRow: 2,
  nextAnalysisSourceRow: 2,
  sourceRowCount: 1,
  expiresAt: "2026-08-04T10:00:00.000Z",
};

describe("POST /api/internal/jobs/imports", () => {
  beforeEach(() => {
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.startRun.mockReset().mockResolvedValue(true);
    mocks.finishRun.mockReset().mockResolvedValue(true);
    mocks.env.mockReset().mockReturnValue({
      DYNAMIC_IMPORT_ENABLED: "true",
      IMPORT_STAGING_ENCRYPTION_KEY: "x".repeat(43),
    });
    mocks.readPayload.mockReset().mockResolvedValue({});
    mocks.openCsv.mockReset().mockReturnValue({
      headers: ["Relatienummer"],
      records: [["NEW-1"]],
      delimiter: ";",
      rowShapeIssues: [],
    });
    mocks.headerHash.mockReset().mockReturnValue("c".repeat(64));
    mocks.selectedRows.mockReset().mockReturnValue([{
      sourceRow: 2,
      fields: { external_member_id: "NEW-1" },
      sizes: {},
      errors: [],
    }]);
    mocks.rpc.mockReset();
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("stageert uitsluitend geselecteerde rijen en finaliseert een preview", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({ data: { job: { ...jobBase, phase: "preview" } }, error: null });
      }
      if (name === "stage_dynamic_import_rows") {
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            accepted: 1,
            nextSourceRow: 3,
            complete: true,
            reused: false,
          },
          error: null,
        });
      }
      if (name === "analyze_dynamic_import_chunk") {
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            processed: 1,
            nextSourceRow: 3,
            complete: true,
          },
          error: null,
        });
      }
      if (name === "finalize_dynamic_import_dry_run") {
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            status: "previewed",
            outcomeCounts: { create: 1, update: 0, skip: 0, protected: 0, conflict: 0, error: 0 },
            hasBlockers: false,
            planHash: "e".repeat(64),
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "previewed", processed: 2 });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "stage_dynamic_import_rows",
      expect.objectContaining({
        p_rows: [{
          sourceRow: 2,
          fields: { external_member_id: "NEW-1" },
          sizes: {},
          errors: [],
        }],
      }),
    );
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "succeeded",
      2,
      null,
    );
  });

  it("verwerkt de afzonderlijk geautoriseerde commitfase", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({ data: { job: { ...jobBase, phase: "commit" } }, error: null });
      }
      if (name === "commit_dynamic_import_chunk") {
        return Promise.resolve({
          data: { runId: jobBase.runId, processed: 1, nextSourceRow: 3, complete: true },
          error: null,
        });
      }
      if (name === "finalize_dynamic_import_commit") {
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            batchId: jobBase.batchId,
            status: "committed",
            committedAt: "2026-08-03T10:00:00.000Z",
            outcomeCounts: { create: 1, update: 0, skip: 0, protected: 0, conflict: 0, error: 0 },
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "committed", processed: 1 });
    expect(mocks.readPayload).not.toHaveBeenCalled();
  });

  it("pauzeert zonder claim wanneer de runtimepoort dicht staat", async () => {
    mocks.env.mockReturnValueOnce({
      DYNAMIC_IMPORT_ENABLED: "false",
      IMPORT_STAGING_ENCRYPTION_KEY: undefined,
    });
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "paused", claimed: 0 });
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("weigert een ongeldige bearer vóór databasegebruik", async () => {
    mocks.bearer.mockReturnValueOnce(false);
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.startRun).not.toHaveBeenCalled();
  });

  it("weigert een niet-lege workerbody vóór databasegebruik", async () => {
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST", body: "{}" },
    ));
    expect(response.status).toBe(413);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("faalt gesloten wanneer de adminclient of runledger ontbreekt", async () => {
    mocks.admin.mockReturnValueOnce(null);
    const unavailable = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(unavailable.status).toBe(503);

    mocks.admin.mockReturnValueOnce({ schema: () => ({ rpc: mocks.rpc }) });
    mocks.startRun.mockResolvedValueOnce(false);
    const unmonitored = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(unmonitored.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "failed",
      0,
      "start_failed",
    );
  });

  it("sluit een gestarte operation-run bij env- of claimfouten", async () => {
    mocks.env.mockImplementationOnce(() => {
      throw new Error("invalid env");
    });
    const envFailure = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(envFailure.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenLastCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "failed",
      0,
      "processing_failed",
    );

    mocks.rpc.mockRejectedValueOnce(new Error("database unavailable"));
    const claimFailure = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(claimFailure.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenLastCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "failed",
      0,
      "processing_failed",
    );
  });

  it("registreert een ongeldig claimantwoord en een idle claim expliciet", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: { unexpected: true }, error: null });
    const invalid = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(invalid.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenLastCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "failed",
      0,
      "claim_failed",
    );

    mocks.rpc.mockResolvedValueOnce({ data: { job: null }, error: null });
    const idle = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(idle.status).toBe(200);
    expect(await idle.json()).toEqual({ status: "idle", claimed: 0, processed: 0 });
  });

  it("legt catalogus- en state-drift definitief en PII-vrij vast", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({
          data: { job: { ...jobBase, phase: "preview", catalogCurrent: false } },
          error: null,
        });
      }
      if (name === "fail_dynamic_import_run") {
        return Promise.resolve({
          data: { runId: jobBase.runId, status: "failed", failureCode: "catalog_changed" },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    const catalog = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(catalog.status).toBe(503);
    expect(await catalog.json()).toEqual({ status: "failed", claimed: 1, processed: 0 });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "fail_dynamic_import_run",
      expect.objectContaining({ p_failure_code: "catalog_changed" }),
    );

    mocks.rpc.mockReset().mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({ data: { job: { ...jobBase, phase: "commit" } }, error: null });
      }
      if (name === "commit_dynamic_import_chunk") {
        return Promise.resolve({
          data: null,
          error: { message: "DYNAMIC_IMPORT_STATE_DRIFT" },
        });
      }
      if (name === "fail_dynamic_import_run") {
        return Promise.resolve({
          data: { runId: jobBase.runId, status: "failed", failureCode: "state_drift" },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    const state = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(state.status).toBe(503);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "fail_dynamic_import_run",
      expect.objectContaining({ p_failure_code: "state_drift" }),
    );
  });

  it("laat een failure-RPC-fout niet als succesvolle worker eindigen", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({
          data: { job: { ...jobBase, phase: "preview", catalogCurrent: false } },
          error: null,
        });
      }
      if (name === "fail_dynamic_import_run") {
        return Promise.resolve({ data: null, error: { message: "lease lost" } });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "Importverwerking wordt na de lease veilig hervat.",
    });
    expect(mocks.finishRun).toHaveBeenLastCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "failed",
      0,
      "processing_failed",
    );
  });

  it("begrensd een grote commit op duizend rijen per worker-aanroep", async () => {
    let nextSourceRow = 2;
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({
          data: {
            job: {
              ...jobBase,
              phase: "commit",
              sourceRowCount: 2_000,
              nextSourceRow: 2,
            },
          },
          error: null,
        });
      }
      if (name === "commit_dynamic_import_chunk") {
        nextSourceRow += 250;
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            processed: 250,
            nextSourceRow,
            complete: false,
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "processing",
      claimed: 1,
      processed: 1_000,
    });
    expect(
      mocks.rpc.mock.calls.filter(([name]) => name === "commit_dynamic_import_chunk"),
    ).toHaveLength(4);
    expect(
      mocks.rpc.mock.calls.some(([name]) => name === "finalize_dynamic_import_commit"),
    ).toBe(false);
  });

  it("stageert een grote preview hervatbaar in vier begrensde chunks", async () => {
    mocks.openCsv.mockReturnValueOnce({
      headers: ["Relatienummer"],
      records: Array.from({ length: 2_000 }, (_, index) => [`LARGE-${index + 1}`]),
      delimiter: ";",
      rowShapeIssues: [],
    });
    mocks.selectedRows.mockImplementation(
      ({ startSourceRow, limit }: { startSourceRow: number; limit: number }) =>
        Array.from({ length: limit }, (_, index) => ({
          sourceRow: startSourceRow + index,
          fields: { external_member_id: `LARGE-${startSourceRow + index}` },
          sizes: {},
          errors: [],
        })),
    );
    let nextSourceRow = 2;
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({
          data: {
            job: {
              ...jobBase,
              phase: "preview",
              sourceRowCount: 2_000,
              nextSourceRow: 2,
              nextAnalysisSourceRow: 2,
            },
          },
          error: null,
        });
      }
      if (name === "stage_dynamic_import_rows") {
        nextSourceRow += 250;
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            accepted: 250,
            nextSourceRow,
            complete: false,
            reused: false,
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "processing",
      claimed: 1,
      processed: 1_000,
    });
    expect(mocks.readPayload).toHaveBeenCalledTimes(1);
    expect(
      mocks.rpc.mock.calls.filter(([name]) => name === "stage_dynamic_import_rows"),
    ).toHaveLength(4);
    expect(
      mocks.rpc.mock.calls.some(([name]) => name === "analyze_dynamic_import_chunk"),
    ).toBe(false);
  });

  it("hervat analyse zonder de versleutelde upload opnieuw te openen", async () => {
    let nextSourceRow = 2;
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({
          data: {
            job: {
              ...jobBase,
              phase: "preview",
              sourceRowCount: 2_000,
              nextSourceRow: 2_002,
              nextAnalysisSourceRow: 2,
            },
          },
          error: null,
        });
      }
      if (name === "analyze_dynamic_import_chunk") {
        nextSourceRow += 250;
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            processed: 250,
            nextSourceRow,
            complete: false,
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "processing",
      claimed: 1,
      processed: 1_000,
    });
    expect(mocks.readPayload).not.toHaveBeenCalled();
    expect(
      mocks.rpc.mock.calls.filter(([name]) => name === "analyze_dynamic_import_chunk"),
    ).toHaveLength(4);
    expect(
      mocks.rpc.mock.calls.some(([name]) => name === "finalize_dynamic_import_dry_run"),
    ).toBe(false);
  });

  it("sluit een analyse zonder voortgang fail-closed af", async () => {
    mocks.rpc.mockImplementation((name: string) => {
      if (name === "claim_dynamic_import_run") {
        return Promise.resolve({
          data: {
            job: {
              ...jobBase,
              phase: "preview",
              nextSourceRow: 3,
              nextAnalysisSourceRow: 2,
            },
          },
          error: null,
        });
      }
      if (name === "analyze_dynamic_import_chunk") {
        return Promise.resolve({
          data: {
            runId: jobBase.runId,
            processed: 0,
            nextSourceRow: 2,
            complete: false,
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/imports",
      { method: "POST" },
    ));
    expect(response.status).toBe(503);
    expect(mocks.finishRun).toHaveBeenLastCalledWith(
      expect.anything(),
      "import_worker",
      expect.any(String),
      "failed",
      0,
      "processing_failed",
    );
  });
});
