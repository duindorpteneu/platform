import { unstable_noStore as noStore } from "next/cache";
import { dashboardOverviewSchema } from "@/lib/dashboard-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getBackofficeDashboard() {
  noStore();
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("DASHBOARD_DATABASE_UNAVAILABLE");

  const { data, error } = await supabase.schema("app").rpc("get_backoffice_dashboard");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("DASHBOARD_QUERY_FAILED");
  }

  const parsed = dashboardOverviewSchema.safeParse(data);
  if (!parsed.success) throw new Error("DASHBOARD_RESPONSE_INVALID");
  return { overview: parsed.data, staff };
}
