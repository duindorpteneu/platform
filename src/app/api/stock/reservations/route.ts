import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard }); if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    return NextResponse.json(
      { error: "Handmatige reservering is vervangen door betaald en maatgeldig FIFO." },
      { status: 410 },
    );
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot voorraadreserveringen." }, { status: 403 });
    return NextResponse.json({ error: "De reservering kon niet worden verwerkt." }, { status: 500 });
  }
}
