import { unstable_noStore as noStore } from "next/cache";
import { auditWorkspaceSchema, type AuditFilters, type AuditWorkspace } from "@/lib/settings-audit-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getAuditWorkspace(filters: AuditFilters): Promise<AuditWorkspace> {
  noStore();
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("AUDIT_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_audit_workspace", {
    p_category: filters.category ?? null,
    p_action: filters.action ?? null,
    p_actor_user_id: filters.actorUserId ?? null,
    p_before: filters.before ?? null,
    p_limit: filters.limit,
  });
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    if (error.code === "22023") throw new Error("AUDIT_FILTER_INVALID");
    throw new Error("AUDIT_WORKSPACE_QUERY_FAILED");
  }
  const parsed = auditWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("AUDIT_WORKSPACE_RESPONSE_INVALID");
  return parsed.data;
}
