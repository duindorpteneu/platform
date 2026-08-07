import {
  releaseControlWorkspaceSchema,
  type ManageReleaseControlRequest,
  type ReleaseControlWorkspace,
} from "@/lib/release-control-contract";
import { requireStaffRole } from "@/server/auth/staff";
import {
  qrKeyVersion,
  qrPepperFingerprint,
} from "@/server/qr/tokens";
import { getSupabaseServerClient } from "@/server/supabase/server";

async function client() {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("RELEASE_CONTROLS_DATABASE_UNAVAILABLE");
  return supabase;
}

export async function getReleaseControlWorkspace(): Promise<
  ReleaseControlWorkspace
> {
  const supabase = await client();
  const keyVersion = qrKeyVersion();
  const fingerprint = qrPepperFingerprint(keyVersion);
  const [base, parentAccess, allocationQr] = await Promise.all([
    supabase.schema("app").rpc("get_release_feature_controls_v1"),
    supabase.schema("app").rpc("get_parent_access_cutover_status"),
    supabase.schema("app").rpc("get_allocation_qr_cutover_snapshot_v2", {
      p_pepper_fingerprint: fingerprint,
      p_key_version: keyVersion,
    }),
  ]);
  const error = base.error ?? parentAccess.error ?? allocationQr.error;
  if (error) {
    if (error.code === "42501") {
      throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    }
    throw new Error("RELEASE_CONTROLS_QUERY_FAILED");
  }
  const parsed = releaseControlWorkspaceSchema.safeParse({
    base: base.data,
    parentAccess: parentAccess.data,
    allocationQr: allocationQr.data,
  });
  if (!parsed.success) {
    throw new Error("RELEASE_CONTROLS_RESPONSE_INVALID");
  }
  return parsed.data;
}

export async function changeReleaseControl(
  input: ManageReleaseControlRequest,
  correlationId: string | null,
) {
  const supabase = await client();
  let result;
  if (input.action === "pause") {
    result = await supabase.schema("app").rpc(
      "pause_release_feature_v1",
      {
        p_key: input.key,
        p_reason: input.reason,
        p_correlation_id: correlationId,
      },
    );
  } else if (input.key === "parent_access_grants_v2") {
    result = await supabase.schema("app").rpc(
      "enable_parent_access_grants_v2",
      {
        p_expected_revision: input.expectedRevision,
        p_correlation_id: correlationId,
      },
    );
  } else if (input.key === "allocation_qr_v2") {
    const keyVersion = qrKeyVersion();
    result = await supabase.schema("app").rpc(
      "activate_allocation_qr_v2",
      {
        p_expected_revision: input.expectedRevision,
        p_pepper_fingerprint: qrPepperFingerprint(keyVersion),
        p_key_version: keyVersion,
        p_reason: input.reason,
        p_correlation_id: correlationId,
      },
    );
  } else {
    result = await supabase.schema("app").rpc(
      "activate_release_feature_v1",
      {
        p_key: input.key,
        p_expected_revision: input.expectedRevision,
        p_reason: input.reason,
        p_correlation_id: correlationId,
      },
    );
  }
  if (result.error) return { data: null, error: result.error };
  return { data: await getReleaseControlWorkspace(), error: null };
}
