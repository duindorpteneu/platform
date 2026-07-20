import { NextResponse } from "next/server";
import { getStaffContext, getStaffLandingPath } from "@/server/auth/staff";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

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
