import { unstable_noStore as noStore } from "next/cache";
import { catalogOrderWorkspaceSchema } from "@/lib/catalog-order-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getCatalogOrderWorkspace() {
  noStore();
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("CATALOG_DATABASE_UNAVAILABLE");

  const [{ data, error }, { data: seasons, error: seasonsError }, { data: teamOptions, error: teamsError }] = await Promise.all([
    supabase.schema("app").rpc("get_catalog_order_workspace_v4"),
    supabase.schema("app").rpc("get_catalog_seasons"),
    supabase.schema("app").rpc("get_member_team_options"),
  ]);
  if (error || seasonsError || teamsError) {
    if (error?.code === "42501" || seasonsError?.code === "42501" || teamsError?.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("CATALOG_WORKSPACE_QUERY_FAILED");
  }
  const parsed = catalogOrderWorkspaceSchema.safeParse({ ...(data as object), seasons, teamOptions });
  if (!parsed.success) throw new Error("CATALOG_WORKSPACE_RESPONSE_INVALID");
  return {
    workspace: staff.role === "beheerder"
      ? parsed.data
      : { ...parsed.data, packageSizeChangeRequests: [] },
    staff,
  };
}
