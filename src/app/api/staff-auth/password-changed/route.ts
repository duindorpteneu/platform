import { NextResponse } from "next/server";
import { revokeAllStaffSessionsForUser, STAFF_SESSION_COOKIE, StaffSessionUnavailableError } from "@/server/auth/staff-context";
import { guardBrowserMutation, readEmptyRequest } from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function responseWithClearedStaffCookie(status: number) {
  const response = new NextResponse(null, { status, headers: { "Cache-Control": "private, no-store, max-age=0" } });
  response.cookies.set(STAFF_SESSION_COOKIE, "", {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 0,
  });
  return response;
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: false });
  if (guarded) return guarded;
  const empty = await readEmptyRequest(request);
  if (!empty.ok) return empty.response;

  const supabase = await getSupabaseServerClient();
  if (!supabase) return responseWithClearedStaffCookie(503);
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return responseWithClearedStaffCookie(401);
  try {
    const revoked = await revokeAllStaffSessionsForUser(data.user.id);
    return responseWithClearedStaffCookie(revoked ? 204 : 403);
  } catch (error) {
    if (error instanceof StaffSessionUnavailableError) return responseWithClearedStaffCookie(503);
    throw error;
  }
}
