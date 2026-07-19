import { getServerEnv } from "@/lib/env";
import { staffMutationResponseSchema, type StaffRole } from "@/lib/settings-audit-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function inviteStaff(input: { email: string; displayName: string; role: StaffRole }, correlationId: string | null) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  const admin = getSupabaseAdminClient();
  if (!supabase || !admin) throw new Error("STAFF_INVITE_NOT_CONFIGURED");

  const redirectTo = new URL("/staff/set-password", getServerEnv().APP_BASE_URL).toString();
  const invitation = await admin.auth.admin.inviteUserByEmail(input.email, {
    redirectTo,
    data: { display_name: input.displayName },
  });
  const invitedUserId = invitation.data.user?.id;
  if (invitation.error || !invitedUserId) throw new Error("STAFF_INVITE_PROVIDER_FAILED");

  const registration = await supabase.schema("app").rpc("register_invited_staff", {
    p_auth_user_id: invitedUserId,
    p_display_name: input.displayName,
    p_role: input.role,
    p_correlation_id: correlationId,
  });
  if (registration.error) {
    await admin.auth.admin.deleteUser(invitedUserId);
    if (registration.error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("STAFF_INVITE_REGISTRATION_FAILED");
  }
  const parsed = staffMutationResponseSchema.safeParse(registration.data);
  if (!parsed.success) {
    await admin.auth.admin.deleteUser(invitedUserId);
    throw new Error("STAFF_MUTATION_RESPONSE_INVALID");
  }
  return parsed.data;
}
