import {
  applyMemberSavedViewResponseSchema,
  deleteMemberSavedViewResponseSchema,
  memberSavedViewSchema,
  memberSavedViewsResponseSchema,
  type MemberSavedViewFilters,
} from "@/lib/member-overview-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export type MemberSavedViewRpcError = {
  code?: string;
  message?: string;
};

async function savedViewClient() {
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MEMBER_DATABASE_UNAVAILABLE");
  return { staff, supabase };
}

export async function getMemberSavedViews(seasonId: string) {
  const { supabase } = await savedViewClient();
  const { data, error } = await supabase.schema("app").rpc(
    "get_member_saved_views",
    { p_season_id: seasonId },
  );
  if (error) {
    return { data: null, error: error as MemberSavedViewRpcError };
  }
  const parsed = memberSavedViewsResponseSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MEMBER_SAVED_VIEWS_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function saveMemberSavedView(input: {
  viewId: string | null;
  seasonId: string;
  name: string;
  schemaVersion: 1;
  filters: MemberSavedViewFilters;
}) {
  const { supabase } = await savedViewClient();
  const { data, error } = await supabase.schema("app").rpc(
    "save_member_saved_view",
    {
      p_view_id: input.viewId,
      p_season_id: input.seasonId,
      p_name: input.name,
      p_schema_version: input.schemaVersion,
      p_filters: input.filters,
    },
  );
  if (error) {
    return { data: null, error: error as MemberSavedViewRpcError };
  }
  const parsed = memberSavedViewSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MEMBER_SAVED_VIEW_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function deleteMemberSavedView(input: {
  viewId: string;
  seasonId: string;
}) {
  const { supabase } = await savedViewClient();
  const { data, error } = await supabase.schema("app").rpc(
    "delete_member_saved_view",
    {
      p_view_id: input.viewId,
      p_season_id: input.seasonId,
    },
  );
  if (error) {
    return { data: null, error: error as MemberSavedViewRpcError };
  }
  const parsed = deleteMemberSavedViewResponseSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MEMBER_SAVED_VIEW_DELETE_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function applyMemberSavedView(input: {
  viewId: string;
  seasonId: string;
}) {
  const { supabase } = await savedViewClient();
  const { data, error } = await supabase.schema("app").rpc(
    "apply_member_saved_view",
    {
      p_view_id: input.viewId,
      p_season_id: input.seasonId,
    },
  );
  if (error) {
    return { data: null, error: error as MemberSavedViewRpcError };
  }
  const parsed = applyMemberSavedViewResponseSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MEMBER_SAVED_VIEW_APPLY_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}
