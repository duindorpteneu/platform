import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { inventoryDraftCreateSchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function json(body: unknown, status = 200) {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;

  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = inventoryDraftCreateSchema.safeParse(body.data);
    if (!parsed.success) {
      return json({ error: "Controleer datum, leverancier en geselecteerde producten." }, 400);
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) return json({ error: "Databaseverbinding ontbreekt." }, 503);

    const { data, error } = await supabase.schema("app").rpc("create_inventory_delivery_draft", {
      p_season_id: parsed.data.seasonId,
      p_received_on: parsed.data.receivedOn,
      p_supplier: parsed.data.supplier,
      p_packing_slip_reference: parsed.data.packingSlipReference ?? null,
      p_article_ids: parsed.data.articleIds,
      p_request_id: parsed.data.requestId,
    });
    if (error) {
      if (error.code === "42501") return json({ error: "AAL2 en voorraadbevoegdheid zijn vereist." }, 403);
      if (error.code === "23514") return json({ error: "Een product of seizoen is niet meer geldig. Vernieuw en probeer opnieuw." }, 409);
      if (error.code === "23505") return json({ error: "Deze herhaalactie wijkt af van het oorspronkelijke verzoek." }, 409);
      return json({ error: "Het leveringconcept kon niet veilig worden gemaakt." }, 409);
    }
    return json(data, 201);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return json({ error: "Geen toegang tot leveringconcepten." }, 403);
    }
    return json({ error: "Het leveringconcept kon niet worden verwerkt." }, 500);
  }
}
