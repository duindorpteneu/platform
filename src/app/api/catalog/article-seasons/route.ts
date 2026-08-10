import { NextResponse } from "next/server";
import { bulkArticleSeasonRequestSchema, bulkArticleSeasonResponseSchema } from "@/lib/catalog-order-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.articleSeasonBulk });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.articleSeasonBulk);
    if (!body.ok) return body.response;
    const parsed = bulkArticleSeasonRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Selecteer een open seizoen en één of meer unieke artikelen." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("bulk_set_article_season", {
      p_season_id: parsed.data.seasonId,
      p_article_ids: parsed.data.articleIds,
      p_linked: parsed.data.linked,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot seizoenskoppelingen." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Een geselecteerd artikel bestaat niet meer." }, { status: 404 });
      if (error.code === "23514") return NextResponse.json({ error: "Alleen een open seizoen kan worden gewijzigd." }, { status: 409 });
      if (error.code === "23503") return NextResponse.json({ error: "Een artikel in een historische, concept- of actieve pakketrevisie kan niet van dit seizoen worden losgekoppeld." }, { status: 409 });
      return NextResponse.json({ error: "De seizoenskoppelingen konden niet veilig worden opgeslagen." }, { status: 422 });
    }
    const response = bulkArticleSeasonResponseSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json(response.data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot de catalogus." }, { status: 403 });
    return NextResponse.json({ error: "De seizoenskoppelingen konden niet worden verwerkt." }, { status: 500 });
  }
}
