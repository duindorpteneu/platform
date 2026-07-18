import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { fulfilmentCommitRequestSchema, hashQrBearerToken } from "@/server/qr/tokens";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  try {
    await requireStaffRole();
    const parsed = fulfilmentCommitRequestSchema.safeParse(await request.json());
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige uitgifteselectie." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const { data, error } = await supabase.schema("app").rpc("commit_fulfilment", {
      p_order_id: parsed.data.orderId,
      p_order_line_ids: parsed.data.orderLineIds,
      p_location: parsed.data.location,
      p_token_hash: hashQrBearerToken(parsed.data.token),
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot uitgifte." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Bestelling niet gevonden." }, { status: 404 });
      return NextResponse.json({ error: "De uitgifte is geweigerd; vernieuw de scan en controleer betaling en artikelstatus." }, { status: 409 });
    }
    return NextResponse.json(data, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot uitgifte." }, { status: 403 });
    return NextResponse.json({ error: "De uitgifte kon niet worden verwerkt." }, { status: 500 });
  }
}
