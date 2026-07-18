import { unstable_noStore as noStore } from "next/cache";
import { catalogOrderWorkspaceSchema } from "@/lib/catalog-order-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getCatalogOrderWorkspace() {
  noStore();
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("CATALOG_DATABASE_UNAVAILABLE");

  const { data, error } = await supabase.schema("app").rpc("get_catalog_order_workspace");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("CATALOG_WORKSPACE_QUERY_FAILED");
  }
  const parsed = catalogOrderWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("CATALOG_WORKSPACE_RESPONSE_INVALID");
  return { workspace: parsed.data, staff };
}

