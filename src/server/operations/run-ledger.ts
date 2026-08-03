import { operationFinishResponseSchema, operationStartResponseSchema } from "@/lib/operations-contract";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

type AdminClient = NonNullable<ReturnType<typeof getSupabaseAdminClient>>;
export type OperationName = "email_worker" | "import_worker" | "retention";
export type OperationResultStatus = "succeeded" | "failed" | "paused";

export async function startOperationRun(admin: AdminClient, operation: OperationName, runId: string) {
  const { data, error } = await admin.schema("app").rpc("start_operation_run", {
    p_operation: operation,
    p_run_id: runId,
  });
  const parsed = operationStartResponseSchema.safeParse(data);
  return !error && parsed.success && parsed.data.runId === runId && parsed.data.operation === operation;
}

export async function finishOperationRun(
  admin: AdminClient,
  operation: OperationName,
  runId: string,
  status: OperationResultStatus,
  processedCount: number,
  errorCode: string | null = null,
) {
  const { data, error } = await admin.schema("app").rpc("finish_operation_run", {
    p_run_id: runId,
    p_status: status,
    p_processed_count: processedCount,
    p_error_code: errorCode,
  });
  const parsed = operationFinishResponseSchema.safeParse(data);
  return !error
    && parsed.success
    && parsed.data.runId === runId
    && parsed.data.operation === operation
    && parsed.data.status === status;
}
