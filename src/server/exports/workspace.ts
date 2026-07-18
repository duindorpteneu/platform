import { unstable_noStore as noStore } from "next/cache";
import { exportPayloadSchema, exportWorkspaceSchema, type ExportType } from "@/lib/export-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getExportWorkspace() {
  noStore();
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("EXPORT_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_export_workspace");
  if (error) throw new Error(error.code === "42501" ? "STAFF_AUTHORIZATION_REQUIRED" : "EXPORT_WORKSPACE_QUERY_FAILED");
  const parsed = exportWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("EXPORT_WORKSPACE_RESPONSE_INVALID");
  return parsed.data;
}

export async function getExportPayload(type: ExportType, seasonId: string | null, filter: string | null) {
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("EXPORT_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("create_export", { p_type: type, p_season_id: seasonId, p_filter: filter });
  if (error) throw new Error(error.code === "42501" ? "STAFF_AUTHORIZATION_REQUIRED" : "EXPORT_QUERY_FAILED");
  const parsed = exportPayloadSchema.safeParse(data);
  if (!parsed.success) throw new Error("EXPORT_RESPONSE_INVALID");
  return parsed.data;
}

