import { cookies } from "next/headers";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { hashParentSecret } from "@/server/auth/parent";

const COOKIE_NAME = "duindorp_parent_session";

export type ParentSessionPhase = "ready" | "cookie_missing" | "admin_unavailable" | "rpc_error" | "session_not_found";

export async function resolveParentSession() {
  const token = (await cookies()).get(COOKIE_NAME)?.value;
  if (!token) return { session: null, phase: "cookie_missing" as const };
  const admin = getSupabaseAdminClient();
  if (!admin) return { session: null, phase: "admin_unavailable" as const };
  const tokenHash = hashParentSecret(token);
  const { data, error } = await admin.rpc("get_parent_session", { p_token_hash: tokenHash });
  if (error) return { session: null, phase: "rpc_error" as const };
  if (!data?.[0]) return { session: null, phase: "session_not_found" as const };
  return {
    session: {
      tokenHash,
      parentAccountId: data[0].parent_account_id as string,
      email: data[0].email_normalized as string,
    },
    phase: "ready" as const,
  };
}

export async function getParentSession() {
  return (await resolveParentSession()).session;
}
