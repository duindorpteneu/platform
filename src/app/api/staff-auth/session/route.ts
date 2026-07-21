import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import { getStaffLandingPath, staffContextSchema } from "@/lib/staff-auth-contract";
import { getStaffContext } from "@/server/auth/staff";
import { guardBrowserMutation } from "@/server/security/route-guard";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };
const sessionTokensSchema = z.object({
  accessToken: z.string().min(1).max(16_384),
}).strict();

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const staff = await getStaffContext();
  if (!staff) {
    return NextResponse.json(
      { error: "STAFF_ACCESS_REQUIRED" },
      { status: 403, headers: privateHeaders },
    );
  }

  return NextResponse.json(
    { landingPath: getStaffLandingPath(staff.role) },
    { headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: { allowedContentTypes: ["application/json"], maxBytes: 40 * 1024 },
  });
  if (guarded) return guarded;

  const parsed = sessionTokensSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "INVALID_SESSION_TOKENS" }, { status: 400, headers: privateHeaders });
  }

  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
    return NextResponse.json({ error: "STAFF_AUTH_UNAVAILABLE" }, { status: 503, headers: privateHeaders });
  }

  const supabase = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${parsed.data.accessToken}` } },
  });
  const { data, error } = await supabase.schema("app").rpc("get_staff_auth_context");
  const staff = staffContextSchema.safeParse(data);
  if (error || !staff.success) return NextResponse.json({ error: "STAFF_SESSION_REJECTED" }, { status: 403, headers: privateHeaders });

  return NextResponse.json(
    { landingPath: getStaffLandingPath(staff.data.role) },
    { headers: privateHeaders },
  );
}
