import { NextResponse } from "next/server";
import { catalogMutationResponseSchema, catalogVariantRequestSchema } from "@/lib/catalog-order-contract";
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
    const parsed = catalogVariantRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Controleer maat, leverancierscode en volgorde." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const input = parsed.data;
    const { data, error } = await supabase.schema("app").rpc("upsert_catalog_variant", {
      p_article_id: input.articleId,
      p_variant_id: input.variantId ?? null,
      p_size: input.size,
      p_supplier_code: input.supplierCode,
      p_active: input.active,
      p_sort_order: input.sortOrder,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot de catalogus." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Artikelvariant bestaat niet meer." }, { status: 404 });
      if (error.code === "23505") return NextResponse.json({ error: "Deze maat bestaat al voor het artikel." }, { status: 409 });
      if (error.message.includes("USED_VARIANT_SIZE_IMMUTABLE")) return NextResponse.json({ error: "De maat van een gebruikte variant kan niet worden gewijzigd. Maak een nieuwe variant aan." }, { status: 409 });
      if (error.message.includes("PACKAGE_LAST_ACTIVE_VARIANT_REQUIRED")) return NextResponse.json({ error: "Een product in een concept of actief pakket moet minstens één actieve maat houden." }, { status: 409 });
      return NextResponse.json({ error: "De variant kon niet veilig worden opgeslagen." }, { status: 422 });
    }
    const response = catalogMutationResponseSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json({ variantId: response.data }, { status: input.variantId ? 200 : 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot de catalogus." }, { status: 403 });
    return NextResponse.json({ error: "De variant kon niet worden verwerkt." }, { status: 500 });
  }
}
