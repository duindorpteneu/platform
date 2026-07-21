import { getServerEnv } from "@/lib/env";
import { staffContextSchema, type StaffContext } from "@/lib/staff-auth-contract";

const STAFF_CONTEXT_TIMEOUT_MS = 10_000;

export async function fetchStaffContext(accessToken: string): Promise<StaffContext | null> {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || !accessToken) return null;

  try {
    const response = await fetch(new URL("/rest/v1/rpc/get_staff_auth_context", env.NEXT_PUBLIC_SUPABASE_URL), {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Accept-Profile": "app",
        apikey: env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
        Authorization: `Bearer ${accessToken}`,
        "Content-Profile": "app",
        "Content-Type": "application/json",
      },
      body: "{}",
      cache: "no-store",
      signal: AbortSignal.timeout(STAFF_CONTEXT_TIMEOUT_MS),
    });
    if (!response.ok) return null;
    const parsed = staffContextSchema.safeParse(await response.json());
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}
