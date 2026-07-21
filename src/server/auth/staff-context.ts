import { getServerEnv } from "@/lib/env";
import { staffContextSchema, type StaffContext } from "@/lib/staff-auth-contract";
import { z } from "zod";

const STAFF_CONTEXT_TIMEOUT_MS = 10_000;
export const STAFF_SESSION_COOKIE = "duindorp_staff_session";
export class StaffSessionUnavailableError extends Error {
  constructor() { super("STAFF_SESSION_UNAVAILABLE"); }
}

const consumedSessionSchema = z.object({
  sessionToken: z.string().regex(/^[0-9a-f]{64}$/),
  context: staffContextSchema,
}).strict();

async function callStaffSessionRpc(name: string, body: Record<string, string>, throwOnTransportFailure = false) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return null;
  const supabaseUrl = env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = env.SUPABASE_SECRET_KEY;

  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new StaffSessionUnavailableError());
      }, STAFF_CONTEXT_TIMEOUT_MS);
    });
    const request = Promise.resolve().then(async () => {
      const response = await fetch(new URL(`/rest/v1/rpc/${name}`, supabaseUrl), {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Accept-Profile": "app",
          apikey: secretKey,
          Authorization: `Bearer ${secretKey}`,
          "Content-Profile": "app",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok) return null;
      return response.json();
    });
    return await Promise.race([request, deadline]);
  } catch {
    if (throwOnTransportFailure) throw new StaffSessionUnavailableError();
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export async function createStaffSessionForUser(userId: string) {
  const parsed = consumedSessionSchema.safeParse(await callStaffSessionRpc("create_staff_app_session_for_user", {
    p_auth_user_id: userId,
  }, true));
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
