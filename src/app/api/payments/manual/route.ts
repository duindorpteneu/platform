import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { manualPaymentRequestSchema } from "@/server/payments/manual";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const parsed = manualPaymentRequestSchema.safeParse(await request.json());
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige betaalregistratie." }, { status: 400 });

    const { data, error } = await supabase.schema("app").rpc("record_manual_payment", {
      p_order_id: parsed.data.orderId,
      p_method: parsed.data.method,
      p_idempotency_key: randomUUID(),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot deze betaling." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Bestelling niet gevonden." }, { status: 404 });
      return NextResponse.json({ error: "De betaling kon niet veilig worden geregistreerd." }, { status: 409 });
    }
    return NextResponse.json(data, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot deze betaling." }, { status: 403 });
    return NextResponse.json({ error: "De betaling kon niet worden verwerkt." }, { status: 500 });
  }
}
