import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { inventoryThresholdSchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function PUT(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;

  try {
    await requireStaffRole(["beheerder"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
    if (!body.ok) return body.response;
    const parsed = inventoryThresholdSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige voorraaddrempel of reden." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("set_inventory_threshold", {
      p_season_id: parsed.data.seasonId,
      p_threshold: parsed.data.threshold,
      p_reason: parsed.data.reason,
      p_correlation_id: parsed.data.correlationId ?? null,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met AAL2 wijzigen de drempel." }, { status: 403 });
      return NextResponse.json({ error: "De voorraaddrempel kon niet worden opgeslagen." }, { status: 409 });
    }
    return NextResponse.json(data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot voorraadinstellingen." }, { status: 403 });
    }
    return NextResponse.json({ error: "De voorraadinstelling kon niet worden verwerkt." }, { status: 500 });
  }
}
