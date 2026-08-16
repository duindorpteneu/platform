import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { inventoryWorkspaceQuerySchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const url = new URL(request.url);
    const parsed = inventoryWorkspaceQuerySchema.safeParse({
      seasonId: url.searchParams.get("seasonId") ?? undefined,
    });
    if (!parsed.success) return NextResponse.json({ error: "Ongeldige voorraadselectie." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const { data, error } = await supabase.schema("app").rpc("get_inventory_workspace_v2", {
      p_season_id: parsed.data.seasonId ?? null,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot voorraad." }, { status: 403 });
      return NextResponse.json({ error: "Het voorraadoverzicht kon niet worden geladen." }, { status: 503 });
    }
    return NextResponse.json(data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot voorraad." }, { status: 403 });
    return NextResponse.json({ error: "Het voorraadoverzicht kon niet worden verwerkt." }, { status: 500 });
  }
}
