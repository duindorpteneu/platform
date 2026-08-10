import { NextResponse } from "next/server";
import { catalogArticleRequestSchema, catalogMutationResponseSchema } from "@/lib/catalog-order-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard }); if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = catalogArticleRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Controleer naam, code, icoon, volgorde en seizoen." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const input = parsed.data;
    const { data, error } = await supabase.schema("app").rpc("upsert_catalog_article", {
      p_article_id: input.articleId ?? null,
      p_name: input.name,
      p_code: input.code,
      p_icon_type: input.iconType,
      p_active: input.active,
      p_sort_order: input.sortOrder,
      p_season_ids: input.seasonIds,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot de catalogus." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Artikel of seizoen bestaat niet meer." }, { status: 404 });
      if (error.code === "23505") return NextResponse.json({ error: "Deze artikelnaam of code bestaat al." }, { status: 409 });
      if (error.message.includes("PACKAGE_PRODUCT_STILL_IN_USE")) return NextResponse.json({ error: "Dit artikel staat in een concept of actief pakket. Pas dat pakket eerst aan." }, { status: 409 });
      return NextResponse.json({ error: "Het artikel kon niet veilig worden opgeslagen." }, { status: 422 });
    }
    const response = catalogMutationResponseSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json({ articleId: response.data }, { status: input.articleId ? 200 : 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot de catalogus." }, { status: 403 });
    return NextResponse.json({ error: "Het artikel kon niet worden verwerkt." }, { status: 500 });
  }
}
