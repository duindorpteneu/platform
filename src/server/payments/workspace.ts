import { unstable_noStore as noStore } from "next/cache";
import { paymentWorkspaceSchema } from "@/lib/payment-workspace-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getPaymentWorkspace() {
  noStore();
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("PAYMENT_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_payment_workspace");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("PAYMENT_WORKSPACE_QUERY_FAILED");
  }
  const parsed = paymentWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("PAYMENT_WORKSPACE_RESPONSE_INVALID");
  return {
    ...parsed.data,
    canRecordRefund: staff.role === "beheerder",
  };
}
