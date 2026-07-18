import { getSupabaseServerClient } from "@/server/supabase/server";

export const STAFF_ROLES = ["beheerder", "kledingcommissie", "uitgifte"] as const;
export type StaffRole = (typeof STAFF_ROLES)[number];

export type StaffContext = {
  userId: string;
  displayName: string;
  role: StaffRole;
};

export async function getStaffContext(): Promise<StaffContext | null> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) return null;

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: profile } = await supabase
    .schema("app")
    .from("staff_profiles")
    .select("display_name, role, active")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!profile || !STAFF_ROLES.includes(profile.role as StaffRole)) return null;
  return { userId: user.id, displayName: profile.display_name, role: profile.role as StaffRole };
}

export async function requireStaffRole(allowedRoles?: readonly StaffRole[]) {
  const context = await getStaffContext();
  if (!context || (allowedRoles && !allowedRoles.includes(context.role))) {
    throw new Error("STAFF_AUTHORIZATION_REQUIRED");
  }
  return context;
}
