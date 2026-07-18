import { staffShellContextSchema } from "@/lib/dashboard-contract";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const STAFF_ROLES = ["beheerder", "kledingcommissie", "uitgifte"] as const;
export type StaffRole = (typeof STAFF_ROLES)[number];

export type StaffContext = {
  userId: string;
  displayName: string;
  role: StaffRole;
  activeSeason: { id: string; name: string } | null;
};

export function hasAal2(level: string | null | undefined) {
  return level === "aal2";
}

export function getStaffLandingPath(role: StaffRole) {
  return role === "uitgifte" ? "/uitgifte" : "/backoffice";
}

export async function getStaffContext(): Promise<StaffContext | null> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) return null;

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: assurance, error: assuranceError } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (assuranceError || !hasAal2(assurance?.currentLevel)) return null;

  const { data: profile } = await supabase
    .schema("app")
    .from("staff_profiles")
    .select("display_name, role, active")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!profile || !STAFF_ROLES.includes(profile.role as StaffRole)) return null;

  const { data: shell, error: shellError } = await supabase.schema("app").rpc("get_staff_shell_context");
  if (shellError) return null;
  const parsedShell = staffShellContextSchema.safeParse(shell);
  if (!parsedShell.success) return null;

  return { userId: user.id, displayName: profile.display_name, role: profile.role as StaffRole, activeSeason: parsedShell.data.activeSeason };
}

export async function requireStaffRole(allowedRoles?: readonly StaffRole[]) {
  const context = await getStaffContext();
  if (!context || (allowedRoles && !allowedRoles.includes(context.role))) {
    throw new Error("STAFF_AUTHORIZATION_REQUIRED");
  }
  return context;
}
