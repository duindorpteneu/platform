import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { stockReservationRequestSchema } from "@/server/stock/requests";
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
    const parsed = stockReservationRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige voorraadreservering." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const { data, error } = await supabase.schema("app").rpc("reserve_order_lines_v2", {
      p_receipt_line_id: parsed.data.receiptLineId,
      p_order_line_ids: parsed.data.orderLineIds,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot voorraadreserveringen." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Leveringsregel niet gevonden." }, { status: 404 });
      return NextResponse.json({ error: "De reservering is geweigerd; controleer voorraad en regelstatus." }, { status: 409 });
    }
    return NextResponse.json(data, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot voorraadreserveringen." }, { status: 403 });
    return NextResponse.json({ error: "De reservering kon niet worden verwerkt." }, { status: 500 });
  }
}
