import { NextResponse } from "next/server";
import { z } from "zod";
import { requireStaffRole } from "@/server/auth/staff";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { inventoryDraftPostSchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const paramsSchema = z.object({ draftId: z.string().uuid() }).strict();

export async function POST(request: Request, context: { params: Promise<{ draftId: string }> }) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;

  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const params = paramsSchema.safeParse(await context.params);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = inventoryDraftPostSchema.safeParse(body.data);
    if (!params.success || !parsed.success) {
      return NextResponse.json({ error: "Ongeldige definitieve levering." }, { status: 400 });
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("post_inventory_delivery_draft", {
      p_draft_id: params.data.draftId,
      p_expected_revision: parsed.data.expectedRevision,
      p_request_id: parsed.data.requestId,
      p_correlation_id: parsed.data.correlationId ?? null,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "AAL2 en voorraadbevoegdheid zijn vereist." }, { status: 403 });
      if (error.code === "55000") return NextResponse.json({ error: "De nieuwe voorraadketen is nog niet gecontroleerd geactiveerd." }, { status: 409 });
      if (error.code === "P0002") return NextResponse.json({ error: "Leveringconcept niet gevonden." }, { status: 404 });
      return NextResponse.json({ error: "Alle maatregels moeten afzonderlijk bevestigd zijn; vernieuw bij gelijktijdige wijzigingen." }, { status: 409 });
    }
    return NextResponse.json(data, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot definitieve leveringen." }, { status: 403 });
    }
    return NextResponse.json({ error: "De levering kon niet worden verwerkt." }, { status: 500 });
  }
}
