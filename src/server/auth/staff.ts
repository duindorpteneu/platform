import {
  getStaffLandingPath,
  hasAal2,
  STAFF_ROLES,
  staffContextSchema,
  type StaffContext,
  type StaffRole,
} from "@/lib/staff-auth-contract";
import { getSupabaseServerClient } from "@/server/supabase/server";

export { getStaffLandingPath, hasAal2, STAFF_ROLES, staffContextSchema };
export type { StaffContext, StaffRole };

export async function getStaffContext(): Promise<StaffContext | null> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) return null;

  const { data, error } = await supabase.schema("app").rpc("get_staff_auth_context");
  if (error) return null;
  const parsed = staffContextSchema.safeParse(data);
  return parsed.success ? parsed.data : null;
}

export async function requireStaffRole(allowedRoles?: readonly StaffRole[]) {
  const context = await getStaffContext();
  if (!context || (allowedRoles && !allowedRoles.includes(context.role))) {
    throw new Error("STAFF_AUTHORIZATION_REQUIRED");
  }
  return context;
}
