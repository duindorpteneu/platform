import { NextResponse } from "next/server";
import { memberStatusRequestSchema, memberStatusResponseSchema } from "@/lib/member-overview-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
    if (!body.ok) return body.response;
    const parsed = memberStatusRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Vul een reden van minimaal drie tekens in." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("set_member_active_for_season", {
      p_member_id: parsed.data.memberId,
      p_active: parsed.data.active,
      p_reason: parsed.data.reason,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot ledenbeheer." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Dit lid bestaat niet meer." }, { status: 404 });
      if (error.code === "23514") return NextResponse.json({ error: "Er is geen open actief seizoen voor deze wijziging." }, { status: 409 });
      return NextResponse.json({ error: "De lidstatus kon niet veilig worden opgeslagen." }, { status: 422 });
    }
    const response = memberStatusResponseSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json(response.data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot ledenbeheer." }, { status: 403 });
    return NextResponse.json({ error: "De lidstatus kon niet worden verwerkt." }, { status: 500 });
  }
}
