import {
  getStaffLandingPath,
  hasAal2,
  STAFF_ROLES,
  staffContextSchema,
  type StaffContext,
  type StaffRole,
} from "@/lib/staff-auth-contract";
import { fetchStaffContext } from "@/server/auth/staff-context";
import { getSupabaseServerClient } from "@/server/supabase/server";

export { getStaffLandingPath, hasAal2, STAFF_ROLES, staffContextSchema };
export type { StaffContext, StaffRole };

export async function getStaffContext(): Promise<StaffContext | null> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) return null;

  const { data, error } = await supabase.auth.getSession();
  if (error || !data.session?.access_token) return null;
  return fetchStaffContext(data.session.access_token);
}

export async function requireStaffRole(allowedRoles?: readonly StaffRole[]) {
  const context = await getStaffContext();
  if (!context || (allowedRoles && !allowedRoles.includes(context.role))) {
    throw new Error("STAFF_AUTHORIZATION_REQUIRED");
  }
  return context;
}
