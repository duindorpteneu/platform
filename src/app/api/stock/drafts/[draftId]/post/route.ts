import { NextResponse } from "next/server";
import { z } from "zod";
import { requireStaffRole } from "@/server/auth/staff";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { inventoryDraftPostSchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const paramsSchema = z.object({ draftId: z.string().uuid() }).strict();

function json(body: unknown, status = 200) {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

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
      return json({ error: "Ongeldige definitieve levering." }, 400);
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) return json({ error: "Databaseverbinding ontbreekt." }, 503);
    const { data, error } = await supabase.schema("app").rpc("post_inventory_delivery_draft", {
      p_draft_id: params.data.draftId,
      p_expected_revision: parsed.data.expectedRevision,
      p_request_id: parsed.data.requestId,
      p_correlation_id: parsed.data.correlationId ?? null,
    });
    if (error) {
      if (error.code === "42501") return json({ error: "AAL2 en voorraadbevoegdheid zijn vereist." }, 403);
      if (error.code === "55000") return json({ error: "De nieuwe voorraadketen is nog niet gecontroleerd geactiveerd." }, 409);
      if (error.code === "P0002") return json({ error: "Leveringconcept niet gevonden." }, 404);
      return json({ error: "Alle maatregels moeten afzonderlijk bevestigd zijn; vernieuw bij gelijktijdige wijzigingen." }, 409);
    }
    return json(data, 201);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return json({ error: "Geen toegang tot definitieve leveringen." }, 403);
    }
    return json({ error: "De levering kon niet worden verwerkt." }, 500);
  }
}
