import { getServerEnv } from "@/lib/env";
import { staffContextSchema, type StaffContext } from "@/lib/staff-auth-contract";
import { z } from "zod";

const STAFF_CONTEXT_TIMEOUT_MS = 10_000;
export const STAFF_SESSION_COOKIE = "duindorp_staff_session";

const consumedSessionSchema = z.object({
  sessionToken: z.string().regex(/^[0-9a-f]{64}$/),
  context: staffContextSchema,
}).strict();

async function callStaffSessionRpc(name: string, body: Record<string, string>) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return null;

  try {
    const response = await fetch(new URL(`/rest/v1/rpc/${name}`, env.NEXT_PUBLIC_SUPABASE_URL), {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Accept-Profile": "app",
        apikey: env.SUPABASE_SECRET_KEY,
        Authorization: `Bearer ${env.SUPABASE_SECRET_KEY}`,
        "Content-Profile": "app",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      cache: "no-store",
      signal: AbortSignal.timeout(STAFF_CONTEXT_TIMEOUT_MS),
    });
    if (!response.ok) return null;
    return response.json();
  } catch {
    return null;
  }
}

export async function createStaffSessionForUser(userId: string) {
  const parsed = consumedSessionSchema.safeParse(await callStaffSessionRpc("create_staff_app_session_for_user", {
    p_auth_user_id: userId,
  }));
  return parsed.success ? parsed.data : null;
}

export async function fetchStaffContext(sessionToken: string): Promise<StaffContext | null> {
  const parsed = staffContextSchema.safeParse(await callStaffSessionRpc("get_staff_app_session", {
    p_session_token: sessionToken,
  }));
  return parsed.success ? parsed.data : null;
}

export async function revokeStaffSession(sessionToken: string) {
  const result = await callStaffSessionRpc("revoke_staff_app_session", { p_session_token: sessionToken });
  return typeof result === "number" && result > 0;
}
