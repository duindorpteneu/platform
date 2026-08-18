import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import {
  dynamicImportAnalysisResponseSchema,
  dynamicImportCommitChunkResponseSchema,
  dynamicImportCommitFinalizeResponseSchema,
  dynamicImportFinalizeResponseSchema,
  dynamicImportStageResponseSchema,
  dynamicImportWorkerClaimSchema,
  selectedImportRowSchema,
  type DynamicImportWorkerClaim,
} from "@/lib/import-contract";
import { getServerEnv } from "@/lib/env";
import { importHeaderHash, openStagedCsv } from "@/server/imports/mapping";
import { buildSelectedImportRows } from "@/server/imports/selected-rows";
import { readStagedImportPayload } from "@/server/imports/workspace";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { finishOperationRun, startOperationRun } from "@/server/operations/run-ledger";
import { readEmptyRequest } from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const PREVIEW_ROWS_PER_CHUNK = 250;
const COMMIT_ROWS_PER_CHUNK = 50;
// A scheduler request hands control back after one database transaction. This
// keeps a commit safely below the 55-second scheduler/lease boundary and stops
// an aborted request from continuing while the next cycle evaluates the run.
const MAX_PREVIEW_ROWS_PER_INVOCATION = PREVIEW_ROWS_PER_CHUNK;
const MAX_COMMIT_ROWS_PER_INVOCATION = COMMIT_ROWS_PER_CHUNK;

type AdminClient = NonNullable<ReturnType<typeof getSupabaseAdminClient>>;
type ImportJob = NonNullable<DynamicImportWorkerClaim["job"]>;

async function failRun(
  admin: AdminClient,
  job: ImportJob,
  claimToken: string,
  failureCode: string,
) {
  const { error } = await admin.schema("app").rpc("fail_dynamic_import_run", {
    p_run_id: job.runId,
    p_claim_token: claimToken,
    p_generation: job.generation,
    p_failure_code: failureCode,
  });
  if (error) throw new Error("DYNAMIC_IMPORT_FAILURE_RECORD_FAILED");
}

function permanentFailureCode(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "DYNAMIC_IMPORT_HEADER_CHANGED") return "header_changed";
  if (code === "DYNAMIC_IMPORT_PAYLOAD_METADATA_MISMATCH") return "payload_metadata_mismatch";
  if (code === "DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE") return "source_unavailable";
  if (code === "DYNAMIC_IMPORT_PAYLOAD_INVALID") return "source_invalid";
  if (code.startsWith("IMPORT_STAGING_")) return "source_integrity_failed";
  return null;
}

async function processPreview(
  admin: AdminClient,
  job: ImportJob,
  claimToken: string,
  encryptionKey: string,
) {
  if (!job.catalogCurrent) {
    await failRun(admin, job, claimToken, "catalog_changed");
    return { status: "failed" as const, processed: 0, errorCode: "catalog_changed" };
  }

  try {
    let nextSourceRow = job.nextSourceRow;
    let nextAnalysisSourceRow = job.nextAnalysisSourceRow;
    let processed = 0;
    const finalSourceRow = job.sourceRowCount + 2;
    let staged = nextSourceRow === finalSourceRow;
    if (!staged) {
      const payload = await readStagedImportPayload({
        batchId: job.batchId,
        actorId: job.actorId,
        seasonId: job.seasonId,
        previewRevision: job.mappingRevision,
      });
      const parsedCsv = openStagedCsv(payload, encryptionKey);
      if (importHeaderHash(parsedCsv.headers) !== job.headerHash) {
        throw new Error("DYNAMIC_IMPORT_HEADER_CHANGED");
      }

      while (!staged && processed < MAX_PREVIEW_ROWS_PER_INVOCATION) {
        const rows = buildSelectedImportRows({
          parsed: parsedCsv,
          mapping: job.mapping,
          startSourceRow: nextSourceRow,
          limit: Math.min(
            PREVIEW_ROWS_PER_CHUNK,
            MAX_PREVIEW_ROWS_PER_INVOCATION - processed,
          ),
        });
        const validatedRows = rows.map((row) => selectedImportRowSchema.parse(row));
        if (validatedRows.length === 0) {
          throw new Error("DYNAMIC_IMPORT_PAYLOAD_METADATA_MISMATCH");
        }
        const filteredResult = await admin.schema("app").rpc(
          "filter_dynamic_import_optional_conflicts",
          {
            p_run_id: job.runId,
            p_claim_token: claimToken,
            p_generation: job.generation,
            p_rows: validatedRows,
          },
        );
        if (filteredResult.error) throw new Error("DYNAMIC_IMPORT_OPTIONAL_FILTER_FAILED");
        const filteredRows = selectedImportRowSchema.array().safeParse(filteredResult.data);
        if (!filteredRows.success || filteredRows.data.length !== validatedRows.length) {
          throw new Error("DYNAMIC_IMPORT_OPTIONAL_FILTER_INVALID");
        }
        const { data, error } = await admin.schema("app").rpc("stage_dynamic_import_rows", {
          p_run_id: job.runId,
          p_claim_token: claimToken,
          p_generation: job.generation,
          p_start_source_row: nextSourceRow,
          p_rows: filteredRows.data,
        });
        if (error) throw new Error("DYNAMIC_IMPORT_STAGE_FAILED");
        const stage = dynamicImportStageResponseSchema.safeParse(data);
        if (!stage.success || stage.data.runId !== job.runId) {
          throw new Error("DYNAMIC_IMPORT_STAGE_RESPONSE_INVALID");
        }
        processed += stage.data.accepted;
        nextSourceRow = stage.data.nextSourceRow;
        staged = stage.data.complete;
      }
    }

    if (!staged) {
      return { status: "processing" as const, processed, errorCode: null };
    }

    let analyzed = nextAnalysisSourceRow === finalSourceRow;
    while (!analyzed && processed < MAX_PREVIEW_ROWS_PER_INVOCATION) {
      const { data, error } = await admin.schema("app").rpc(
        "analyze_dynamic_import_chunk",
        {
          p_run_id: job.runId,
          p_claim_token: claimToken,
          p_generation: job.generation,
          p_limit: Math.min(
            PREVIEW_ROWS_PER_CHUNK,
            MAX_PREVIEW_ROWS_PER_INVOCATION - processed,
          ),
        },
      );
      if (error) {
        if (error.message?.includes("DYNAMIC_IMPORT_PREVIEW_STATE_DRIFT")) {
          await failRun(admin, job, claimToken, "preview_state_drift");
          return {
            status: "failed" as const,
            processed,
            errorCode: "preview_state_drift",
          };
        }
        throw new Error("DYNAMIC_IMPORT_ANALYSIS_FAILED");
      }
      const analysis = dynamicImportAnalysisResponseSchema.safeParse(data);
      if (!analysis.success || analysis.data.runId !== job.runId) {
        throw new Error("DYNAMIC_IMPORT_ANALYSIS_RESPONSE_INVALID");
      }
      processed += analysis.data.processed;
      nextAnalysisSourceRow = analysis.data.nextSourceRow;
      analyzed = analysis.data.complete;
      if (analysis.data.processed === 0 && !analyzed) {
        throw new Error("DYNAMIC_IMPORT_ANALYSIS_NO_PROGRESS");
      }
    }
    if (!analyzed) {
      return { status: "processing" as const, processed, errorCode: null };
    }

    const { data, error } = await admin.schema("app").rpc(
      "finalize_dynamic_import_dry_run",
      {
        p_run_id: job.runId,
        p_claim_token: claimToken,
        p_generation: job.generation,
      },
    );
    if (error) throw new Error("DYNAMIC_IMPORT_FINALIZE_FAILED");
    const finalized = dynamicImportFinalizeResponseSchema.safeParse(data);
    if (!finalized.success || finalized.data.runId !== job.runId) {
      throw new Error("DYNAMIC_IMPORT_FINALIZE_RESPONSE_INVALID");
    }
    return { status: "previewed" as const, processed, errorCode: null };
  } catch (error) {
    const failureCode = permanentFailureCode(error);
    if (failureCode) {
      await failRun(admin, job, claimToken, failureCode);
      return { status: "failed" as const, processed: 0, errorCode: failureCode };
    }
    throw error;
  }
}

async function processCommit(
  admin: AdminClient,
  job: ImportJob,
  claimToken: string,
) {
  if (!job.catalogCurrent) {
    await failRun(admin, job, claimToken, "catalog_changed");
    return { status: "failed" as const, processed: 0, errorCode: "catalog_changed" };
  }

  let processed = 0;
  let complete = job.nextSourceRow === job.sourceRowCount + 2;
  while (!complete && processed < MAX_COMMIT_ROWS_PER_INVOCATION) {
    const { data, error } = await admin.schema("app").rpc(
      "commit_dynamic_import_chunk",
      {
        p_run_id: job.runId,
        p_claim_token: claimToken,
        p_generation: job.generation,
        p_limit: Math.min(
          COMMIT_ROWS_PER_CHUNK,
          MAX_COMMIT_ROWS_PER_INVOCATION - processed,
        ),
      },
    );
    if (error) {
      if (error.message?.includes("DYNAMIC_IMPORT_COMMIT_LEASE_CONFLICT")) {
        return { status: "processing" as const, processed, errorCode: null };
      }
      if (error.message?.includes("DYNAMIC_IMPORT_STATE_DRIFT")) {
        await failRun(admin, job, claimToken, "state_drift");
        return { status: "failed" as const, processed, errorCode: "state_drift" };
      }
      throw new Error("DYNAMIC_IMPORT_COMMIT_CHUNK_FAILED");
    }
    const chunk = dynamicImportCommitChunkResponseSchema.safeParse(data);
    if (!chunk.success || chunk.data.runId !== job.runId) {
      throw new Error("DYNAMIC_IMPORT_COMMIT_CHUNK_RESPONSE_INVALID");
    }
    processed += chunk.data.processed;
    complete = chunk.data.complete;
    if (chunk.data.processed === 0 && !complete) {
      throw new Error("DYNAMIC_IMPORT_COMMIT_NO_PROGRESS");
    }
  }
  if (!complete) return { status: "processing" as const, processed, errorCode: null };

  const { data, error } = await admin.schema("app").rpc(
    "finalize_dynamic_import_commit",
    {
      p_run_id: job.runId,
      p_claim_token: claimToken,
      p_generation: job.generation,
    },
  );
  if (error) {
    if (error.message?.includes("DYNAMIC_IMPORT_STATE_DRIFT")) {
      await failRun(admin, job, claimToken, "state_drift");
      return { status: "failed" as const, processed, errorCode: "state_drift" };
    }
    throw new Error("DYNAMIC_IMPORT_COMMIT_FINALIZE_FAILED");
  }
  const finalized = dynamicImportCommitFinalizeResponseSchema.safeParse(data);
  if (!finalized.success || finalized.data.runId !== job.runId) {
    throw new Error("DYNAMIC_IMPORT_COMMIT_FINALIZE_RESPONSE_INVALID");
  }
  return { status: "committed" as const, processed, errorCode: null };
}

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) {
    return NextResponse.json({ error: "Geen toegang tot de importworker." }, { status: 401 });
  }
  const empty = await readEmptyRequest(request);
  if (!empty.ok) return empty.response;
  let env: ReturnType<typeof getServerEnv>;
  try {
    env = getServerEnv();
  } catch {
    return NextResponse.json(
      { error: "Importworkerconfiguratie is ongeldig." },
      { status: 503 },
    );
  }
  if (env.DYNAMIC_IMPORT_ENABLED !== "true" || !env.IMPORT_STAGING_ENCRYPTION_KEY) {
    return NextResponse.json({ status: "paused", claimed: 0, processed: 0 });
  }
  const admin = getSupabaseAdminClient();
  if (!admin) {
    return NextResponse.json({ error: "Importworker tijdelijk niet beschikbaar." }, { status: 503 });
  }

  const runId = randomUUID();
  let started = false;
  let closeAttempted = false;
  const closeOperation = async (
    status: "succeeded" | "failed" | "paused",
    processed: number,
    errorCode: string | null = null,
  ) => {
    closeAttempted = true;
    return finishOperationRun(
      admin,
      "import_worker",
      runId,
      status,
      processed,
      errorCode,
    );
  };
  try {
    started = await startOperationRun(admin, "import_worker", runId);
    if (!started) {
      return NextResponse.json({ error: "Importworker kon niet worden gemonitord." }, { status: 503 });
    }

    const claimToken = randomUUID();
    const { data, error } = await admin.schema("app").rpc("claim_dynamic_import_run", {
      p_claim_token: claimToken,
      p_lease_seconds: 55,
    });
    const claim = dynamicImportWorkerClaimSchema.safeParse(data);
    if (error || !claim.success) {
      await closeOperation("failed", 0, "claim_failed");
      return NextResponse.json({ error: "Importwerk kon niet veilig worden geclaimd." }, { status: 503 });
    }
    if (!claim.data.job) {
      if (!await closeOperation("succeeded", 0)) {
        return NextResponse.json({ error: "Importworkerresultaat kon niet worden gemonitord." }, { status: 503 });
      }
      return NextResponse.json({ status: "idle", claimed: 0, processed: 0 });
    }

    const job = claim.data.job;
    const result = job.phase === "preview"
      ? await processPreview(
        admin,
        job,
        claimToken,
        env.IMPORT_STAGING_ENCRYPTION_KEY,
      )
      : await processCommit(admin, job, claimToken);
    if (result.status === "processing") {
      const { error: releaseError } = await admin.schema("app").rpc(
        "release_dynamic_import_run_lease",
        {
          p_run_id: job.runId,
          p_claim_token: claimToken,
          p_generation: job.generation,
        },
      );
      if (releaseError) throw new Error("DYNAMIC_IMPORT_LEASE_RELEASE_FAILED");
    }
    // Recording a domain-level run failure is successful worker execution.
    // Partial writes remain a separate, release-blocking database-health axis.
    const recorded = await closeOperation(
      "succeeded",
      result.processed,
      null,
    );
    if (!recorded) {
      return NextResponse.json({ error: "Importworkerresultaat kon niet worden gemonitord." }, { status: 503 });
    }
    return NextResponse.json({
      status: result.status,
      claimed: 1,
      processed: result.processed,
    }, { status: 200 });
  } catch {
    if (started && !closeAttempted) {
      try {
        await closeOperation("failed", 0, "processing_failed");
      } catch {
        // A missing completion record is surfaced by operation-health as a
        // stale running job; never mask the controlled worker response.
      }
    }
    return NextResponse.json({ error: "Importverwerking wordt na de lease veilig hervat." }, { status: 503 });
  }
}
