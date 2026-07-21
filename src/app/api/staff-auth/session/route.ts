import { NextResponse } from "next/server";
import { z } from "zod";
import { getStaffContext, getStaffLandingPath, hasAal2, STAFF_ROLES, type StaffRole } from "@/server/auth/staff";
import { guardBrowserMutation } from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };
const sessionTokensSchema = z.object({
  // Supabase refresh tokens can be short opaque values in local and hosted environments.
  // Authenticity is established by auth.setSession below; this schema only bounds input size.
  accessToken: z.string().min(1).max(16_384),
  refreshToken: z.string().min(1).max(16_384),
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

  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    return NextResponse.json({ error: "STAFF_AUTH_UNAVAILABLE" }, { status: 503, headers: privateHeaders });
  }

  const { data: sessionData, error: sessionError } = await supabase.auth.setSession({
    access_token: parsed.data.accessToken,
    refresh_token: parsed.data.refreshToken,
  });
  if (sessionError || !sessionData.session || !sessionData.user) {
    return NextResponse.json({ error: "STAFF_SESSION_REJECTED" }, { status: 403, headers: privateHeaders });
  }

  const { data: assurance, error: assuranceError } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (assuranceError || !hasAal2(assurance?.currentLevel)) {
    return NextResponse.json({ error: "STAFF_AAL2_REQUIRED" }, { status: 403, headers: privateHeaders });
  }

  const { data: profile } = await supabase
    .schema("app")
    .from("staff_profiles")
    .select("role, active")
    .eq("auth_user_id", sessionData.user.id)
    .eq("active", true)
    .maybeSingle();
  if (!profile || !STAFF_ROLES.includes(profile.role as StaffRole)) {
    return NextResponse.json({ error: "STAFF_PROFILE_REQUIRED" }, { status: 403, headers: privateHeaders });
  }

  return NextResponse.json(
    { landingPath: getStaffLandingPath(profile.role as StaffRole) },
    { headers: privateHeaders },
  );
}
