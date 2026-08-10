import { NextResponse } from "next/server";
import { saveMemberOrderRequestSchema, saveMemberOrderResponseSchema } from "@/lib/catalog-order-contract";
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
    const parsed = saveMemberOrderRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Controleer lid, bedrag en artikelregels." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const input = parsed.data;
    const { data, error } = await supabase.schema("app").rpc("save_member_order", {
      p_member_id: input.memberId,
      p_season_id: input.seasonId,
      p_amount_due_cents: input.amountDueCents,
      p_lines: input.lines.map((line) => ({ variant_id: line.variantId, quantity: line.quantity })),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot bestellingen." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Lid, seizoen of variant bestaat niet meer." }, { status: 404 });
      if (error.message.includes("PAID_ORDER_IMMUTABLE")) return NextResponse.json({ error: "Een betaalde bestelling is alleen-lezen." }, { status: 409 });
      if (error.message.includes("RESERVED_ORDER_LINES_IMMUTABLE")) return NextResponse.json({ error: "Gereserveerde of uitgegeven regels kunnen hier niet worden gewijzigd." }, { status: 409 });
      if (error.message.includes("MEMBER_NOT_ACTIVE")) return NextResponse.json({ error: "Alleen een actief lid kan een bestelling krijgen." }, { status: 409 });
      return NextResponse.json({ error: "De bestelling is geweigerd; vernieuw en controleer seizoen en varianten." }, { status: 422 });
    }
    const response = saveMemberOrderResponseSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json(response.data, { status: 200 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot bestellingen." }, { status: 403 });
    return NextResponse.json({ error: "De bestelling kon niet worden verwerkt." }, { status: 500 });
  }
}
