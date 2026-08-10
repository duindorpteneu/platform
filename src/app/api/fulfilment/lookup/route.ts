import { NextResponse } from "next/server";
import { BODY_POLICIES, readBodyRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const body = await readBodyRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  return NextResponse.json(
    { error: "Deze legacy QR-route is definitief buiten gebruik." },
    {
      status: 410,
      headers: { "Cache-Control": "private, no-store, max-age=0" },
    },
  );
}
