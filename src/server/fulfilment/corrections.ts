import { unstable_noStore as noStore } from "next/cache";
import { fulfilmentCorrectionsWorkspaceSchema } from "@/lib/fulfilment-corrections-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getFulfilmentCorrectionsWorkspace() {
  noStore();
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("CORRECTIONS_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_fulfilment_corrections_workspace");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("CORRECTIONS_QUERY_FAILED");
  }
  const parsed = fulfilmentCorrectionsWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("CORRECTIONS_RESPONSE_INVALID");
  return parsed.data;
}

