import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { manualPaymentRequestSchema } from "@/server/payments/manual";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard }); if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = manualPaymentRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige betaalregistratie." }, { status: 400 });

    const { data, error } = await supabase.schema("app").rpc("record_manual_payment_v2", {
      p_order_id: parsed.data.orderId,
      p_method: parsed.data.method,
      p_amount_cents: parsed.data.amountCents,
      p_reason: parsed.data.reason,
      p_request_id: parsed.data.requestId,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot deze betaling." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Bestelling niet gevonden." }, { status: 404 });
      if (error.message.includes("LEGACY_CARD_PAYMENT_DISABLED")) return NextResponse.json({ error: "Pinregistratie is uitgeschakeld; gebruik Mollie of registreer kas." }, { status: 409 });
      if (error.message.includes("MOLLIE_ATTEMPT_ACTIVE")) return NextResponse.json({ error: "Er loopt al een Mollie-betaling. Controleer die eerst om dubbel betalen te voorkomen." }, { status: 409 });
      if (error.message.includes("MANUAL_PAYMENT_AMOUNT_MISMATCH")) return NextResponse.json({ error: "Het verschuldigde bedrag is intussen gewijzigd. Ververs de pagina." }, { status: 409 });
      if (error.message.includes("MANUAL_PAYMENT_IDEMPOTENCY_CONFLICT")) return NextResponse.json({ error: "Dit betaalverzoek hoort bij andere gegevens. Start de registratie opnieuw." }, { status: 409 });
      if (error.message.includes("ORDER_ALREADY_PAID")) return NextResponse.json({ error: "Deze bestelling is al betaald." }, { status: 409 });
      return NextResponse.json({ error: "De betaling kon niet veilig worden geregistreerd." }, { status: 409 });
    }
    return NextResponse.json(data, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot deze betaling." }, { status: 403 });
    return NextResponse.json({ error: "De betaling kon niet worden verwerkt." }, { status: 500 });
  }
}
