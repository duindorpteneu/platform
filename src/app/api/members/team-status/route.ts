import { NextResponse } from "next/server";
import { teamMemberStatusRequestSchema, teamMemberStatusResponseSchema } from "@/lib/member-overview-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { guardBrowserMutation } from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: { allowedContentTypes: ["application/json"], maxBytes: 10_000 } });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    let body: unknown;
    try { body = await request.json(); } catch { return NextResponse.json({ error: "Ongeldige JSON-aanvraag." }, { status: 400 }); }
    const parsed = teamMemberStatusRequestSchema.safeParse(body);
    if (!parsed.success) return NextResponse.json({ error: "Kies een team en vul bij uitvoeren een reden van minimaal drie tekens in." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const input = parsed.data;
    const result = input.commit
      ? await supabase.schema("app").rpc("bulk_set_team_member_status", {
        p_team: input.team,
        p_active: input.active,
        p_reason: input.reason!,
        p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
      })
      : await supabase.schema("app").rpc("preview_team_member_status", { p_team: input.team, p_active: input.active });

    if (result.error) {
      if (result.error.code === "42501") return NextResponse.json({ error: "Geen toegang tot ledenbeheer." }, { status: 403 });
      if (result.error.code === "P0002") return NextResponse.json({ error: "Dit team bevat geen leden meer." }, { status: 404 });
      if (result.error.code === "23514") return NextResponse.json({ error: "Er is geen open actief seizoen voor deze wijziging." }, { status: 409 });
      return NextResponse.json({ error: "De teamstatus kon niet veilig worden verwerkt." }, { status: 422 });
    }
    const response = teamMemberStatusResponseSchema.safeParse(result.data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json(response.data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot ledenbeheer." }, { status: 403 });
    return NextResponse.json({ error: "De teamstatus kon niet worden verwerkt." }, { status: 500 });
  }
}
