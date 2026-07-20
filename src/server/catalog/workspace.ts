import { unstable_noStore as noStore } from "next/cache";
import { catalogOrderWorkspaceSchema } from "@/lib/catalog-order-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getCatalogOrderWorkspace() {
  noStore();
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("CATALOG_DATABASE_UNAVAILABLE");

  const [{ data, error }, { data: seasons, error: seasonsError }] = await Promise.all([
    supabase.schema("app").rpc("get_catalog_order_workspace"),
    supabase.schema("app").rpc("get_catalog_seasons"),
  ]);
  if (error || seasonsError) {
    if (error?.code === "42501" || seasonsError?.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("CATALOG_WORKSPACE_QUERY_FAILED");
  }
  const parsed = catalogOrderWorkspaceSchema.safeParse({ ...(data as object), seasons });
  if (!parsed.success) throw new Error("CATALOG_WORKSPACE_RESPONSE_INVALID");
  return { workspace: parsed.data, staff };
}
