import { unstable_noStore as noStore } from "next/cache";
import {
  dynamicImportWorkspaceSchema,
  stagedImportPayloadSchema,
  type DynamicImportWorkspaceData,
  type StagedImportPayload,
} from "@/lib/import-contract";
import { getServerEnv } from "@/lib/env";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getDynamicImportWorkspace(): Promise<DynamicImportWorkspaceData> {
  noStore();
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_dynamic_import_workspace");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("DYNAMIC_IMPORT_WORKSPACE_FAILED");
  }
  const parsed = dynamicImportWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("DYNAMIC_IMPORT_WORKSPACE_INVALID");
  const runtimeEnabled = getServerEnv().DYNAMIC_IMPORT_ENABLED === "true";
  return { ...parsed.data, featureEnabled: parsed.data.featureEnabled && runtimeEnabled };
}

export async function readStagedImportPayload(binding: {
  batchId: string;
  actorId: string;
  seasonId: string;
  previewRevision: number;
}): Promise<StagedImportPayload> {
  const admin = getSupabaseAdminClient();
  if (!admin) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
  const { data, error } = await admin.schema("app").rpc("read_dynamic_import_payload_bound", {
    p_batch_id: binding.batchId,
    p_actor_id: binding.actorId,
    p_season_id: binding.seasonId,
    p_preview_revision: binding.previewRevision,
  });
  if (error) {
    if (error.code === "P0002") throw new Error("DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE");
    throw new Error("DYNAMIC_IMPORT_PAYLOAD_READ_FAILED");
  }
  const parsed = stagedImportPayloadSchema.safeParse(data);
  if (!parsed.success) throw new Error("DYNAMIC_IMPORT_PAYLOAD_INVALID");
  return parsed.data;
}
