import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { revokeStaffSession, STAFF_SESSION_COOKIE } from "@/server/auth/staff-context";
import { guardBrowserMutation, readEmptyRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: false });
  if (guarded) return guarded;
  const empty = await readEmptyRequest(request);
  if (!empty.ok) return empty.response;

  const token = (await cookies()).get(STAFF_SESSION_COOKIE)?.value;
  if (token) await revokeStaffSession(token);

  const response = new NextResponse(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  response.cookies.set(STAFF_SESSION_COOKIE, "", {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 0,
  });
  return response;
}
