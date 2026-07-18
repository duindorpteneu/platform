import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { deliveryReceiptRequestSchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { guardBrowserMutation } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request); if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const parsed = deliveryReceiptRequestSchema.safeParse(await request.json());
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige leveringsontvangst." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const { data, error } = await supabase.schema("app").rpc("register_delivery_receipt", {
      p_received_on: parsed.data.receivedOn,
      p_supplier: parsed.data.supplier,
      p_packing_slip_reference: parsed.data.packingSlipReference ?? null,
      p_lines: parsed.data.lines.map((line) => ({ variant_id: line.variantId, quantity: line.quantity })),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot leveringen." }, { status: 403 });
      return NextResponse.json({ error: "De levering kon niet transactioneel worden opgeslagen." }, { status: 409 });
    }
    return NextResponse.json(data, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot leveringen." }, { status: 403 });
    return NextResponse.json({ error: "De levering kon niet worden verwerkt." }, { status: 500 });
  }
}
