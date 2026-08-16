import { NextResponse } from "next/server";
import { memberSizeProfileSchema, memberSizesRequestSchema } from "@/lib/member-overview-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonMedium });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonMedium);
    if (!body.ok) return body.response;
    const parsed = memberSizesRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Controleer de gekozen kledingmaten." }, { status: 400 });

    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("set_member_article_sizes_v2", {
      p_member_id: parsed.data.memberId,
      p_member_season_id: parsed.data.memberSeasonId,
      p_sizes: parsed.data.sizes,
      p_expected_revision: parsed.data.revision,
      p_reason: parsed.data.reason,
      p_request_id: parsed.data.requestId,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot kledingmaten." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Dit lid bestaat niet meer." }, { status: 404 });
      if (error.code === "40001") return NextResponse.json({ error: "De maten zijn intussen gewijzigd. Vernieuw het liddetail en probeer opnieuw." }, { status: 409 });
      if (error.code === "23514") return NextResponse.json({ error: "Een uitgegeven maat is vergrendeld. Een reservering vrijgeven kan alleen als beheerder en met expliciete bevestiging." }, { status: 409 });
      if (error.code === "22023") return NextResponse.json({ error: "Een artikel of maat is niet meer beschikbaar voor dit seizoen." }, { status: 400 });
      return NextResponse.json({ error: "De kledingmaten konden niet veilig worden opgeslagen." }, { status: 422 });
    }
    const response = memberSizeProfileSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json({ sizeProfile: response.data });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot kledingmaten." }, { status: 403 });
    return NextResponse.json({ error: "De kledingmaten konden niet worden verwerkt." }, { status: 500 });
  }
}
