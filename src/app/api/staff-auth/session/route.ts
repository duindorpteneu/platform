import { NextResponse } from "next/server";
import { z } from "zod";
import { getStaffLandingPath } from "@/lib/staff-auth-contract";
import { getStaffContext } from "@/server/auth/staff";
import { fetchStaffContext } from "@/server/auth/staff-context";
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

  const staff = await fetchStaffContext(parsed.data.accessToken);
  if (!staff) return NextResponse.json({ error: "STAFF_SESSION_REJECTED" }, { status: 403, headers: privateHeaders });

  return NextResponse.json(
    { landingPath: getStaffLandingPath(staff.role) },
    { headers: privateHeaders },
  );
}
