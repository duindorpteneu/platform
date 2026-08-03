import { recoverEmailJobResponseSchema, type RecoverEmailJobRequest } from "@/lib/email-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function recoverEmailJob(jobId: string, input: RecoverEmailJobRequest, correlationId: string | null) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("EMAIL_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("recover_stale_email_job_v2", {
    p_job_id: jobId,
    p_expected_updated_at: input.expectedUpdatedAt,
    p_resolution: input.resolution,
    p_reason: input.reason,
    p_provider_evidence_ref: input.providerEvidenceRef,
    p_provider_message_id: input.providerMessageId,
    p_attested_not_accepted: input.attestedNotAccepted,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error };
  const parsed = recoverEmailJobResponseSchema.safeParse(data);
  if (!parsed.success || parsed.data.jobId !== jobId) throw new Error("EMAIL_RECOVERY_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}
