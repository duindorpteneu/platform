import { cookies } from "next/headers";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { hashParentSecret } from "@/server/auth/parent";

const COOKIE_NAME = "duindorp_parent_session";

export async function getParentSession() {
  const token = (await cookies()).get(COOKIE_NAME)?.value;
  const admin = getSupabaseAdminClient();
  if (!token || !admin) return null;
  const { data, error } = await admin.rpc("get_parent_session", { p_token_hash: hashParentSecret(token) });
  if (error || !data?.[0]) return null;
  return { tokenHash: hashParentSecret(token), parentAccountId: data[0].parent_account_id as string, email: data[0].email_normalized as string };
}
