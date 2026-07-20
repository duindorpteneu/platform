import { unstable_noStore as noStore } from "next/cache";
import {
  settingsWorkspaceSchema,
  staffMutationResponseSchema,
  type CreateSeasonRequest,
  type SettingsWorkspace,
  type UpdateSettingsRequest,
} from "@/lib/settings-audit-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getSettingsWorkspace(): Promise<SettingsWorkspace> {
  noStore();
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("SETTINGS_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_settings_workspace_v2");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("SETTINGS_WORKSPACE_QUERY_FAILED");
  }
  const parsed = settingsWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("SETTINGS_WORKSPACE_RESPONSE_INVALID");
  return parsed.data;
}

export async function updateSettings(input: UpdateSettingsRequest, correlationId: string | null) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("SETTINGS_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("update_settings_v2", {
    p_contact_email: input.contactEmail,
    p_club_address_line: input.clubAddressLine,
    p_club_postal_code: input.clubPostalCode,
    p_club_city: input.clubCity,
    p_pickup_address_differs: input.pickupAddressDiffers,
    p_pickup_name: input.pickupName,
    p_pickup_address_line: input.pickupAddressLine,
    p_pickup_postal_code: input.pickupPostalCode,
    p_pickup_city: input.pickupCity,
    p_active_season_id: input.activeSeasonId,
    p_season_amounts: input.seasonAmounts,
    p_mollie_enabled: input.mollieEnabled,
    p_email_enabled: input.emailEnabled,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error };
  const parsed = settingsWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("SETTINGS_WORKSPACE_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function createSeason(input: CreateSeasonRequest, correlationId: string | null) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("SETTINGS_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("create_season_v2", {
    p_name: input.name,
    p_starts_on: input.startsOn,
    p_ends_on: input.endsOn,
    p_default_amount_cents: input.defaultAmountCents,
    p_make_active: input.makeActive,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error };
  const parsed = settingsWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("SETTINGS_WORKSPACE_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function updateStaffProfile(input: { authUserId: string; displayName: string; role: string; active: boolean }, correlationId: string | null) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("SETTINGS_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("update_staff_profile", {
    p_auth_user_id: input.authUserId,
    p_display_name: input.displayName,
    p_role: input.role,
    p_active: input.active,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error };
  const parsed = staffMutationResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("STAFF_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}
