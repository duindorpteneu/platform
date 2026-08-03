import { NextResponse } from "next/server";
import { z } from "zod";
import { supplierPlanningSchema } from "@/lib/supplier-contract";
import { requireSupplierSessionBinding } from "@/server/auth/supplier";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };
const querySchema = z.object({
  seasonId: z.string().uuid().optional(),
}).strict();

export async function GET(request: Request) {
  const url = new URL(request.url);
  const parsedQuery = querySchema.safeParse(
    Object.fromEntries(url.searchParams.entries()),
  );
  if (!parsedQuery.success) {
    return NextResponse.json(
      { error: "Kies een geldig seizoen." },
      { status: 400, headers: privateHeaders },
    );
  }
  try {
    const supplier = await requireSupplierSessionBinding();
    const admin = getSupabaseAdminClient();
    if (!admin) {
      return NextResponse.json(
        { error: "Leveranciersplanning is tijdelijk niet beschikbaar." },
        { status: 503, headers: privateHeaders },
      );
    }
    const { data, error } = await admin.schema("app").rpc(
      "get_supplier_planning_v1",
      {
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
        p_season_id: parsedQuery.data.seasonId ?? null,
        p_session_token_hash: supplier.sessionTokenHash,
      },
    );
    if (error?.code === "42501") {
      return NextResponse.json(
        { error: "SUPPLIER_ACCESS_REQUIRED" },
        { status: 403, headers: privateHeaders },
      );
    }
    if (error?.code === "P0002") {
      return NextResponse.json(
        { error: "Dit seizoen is niet voor deze toegang vrijgegeven." },
        { status: 404, headers: privateHeaders },
      );
    }
    const parsed = supplierPlanningSchema.safeParse(data);
    if (error || !parsed.success) {
      return NextResponse.json(
        { error: "Leveranciersplanning kon niet veilig worden gelezen." },
        { status: 503, headers: privateHeaders },
      );
    }
    return NextResponse.json(parsed.data, { headers: privateHeaders });
  } catch {
    return NextResponse.json(
      { error: "SUPPLIER_ACCESS_REQUIRED" },
      { status: 403, headers: privateHeaders },
    );
  }
}
