import { NextResponse } from "next/server";
import { z } from "zod";
import { dynamicImportBlockedRowSchema } from "@/lib/import-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = {
  "Cache-Control": "private, no-store, max-age=0",
  "Referrer-Policy": "no-referrer",
};
const querySchema = z.object({
  runId: z.string().uuid(),
  sourceRow: z.coerce.number().int().min(2).max(10_001),
}).strict();

export async function GET(request: Request) {
  try {
    await requireStaffRole(["beheerder"]);
    const url = new URL(request.url);
    const input = querySchema.safeParse({
      runId: url.searchParams.get("runId"),
      sourceRow: url.searchParams.get("sourceRow"),
    });
    if (!input.success) {
      return NextResponse.json(
        { error: "De conflictrijquery is ongeldig." },
        { status: 400, headers: privateHeaders },
      );
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
    const { data, error } = await supabase.schema("app").rpc(
      "get_dynamic_import_blocked_row",
      {
        p_run_id: input.data.runId,
        p_source_row: input.data.sourceRow,
      },
    );
    if (error) {
      if (error.code === "42501") {
        throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      }
      if (error.code === "P0002") {
        throw new Error("DYNAMIC_IMPORT_BLOCKED_ROW_NOT_FOUND");
      }
      throw new Error("DYNAMIC_IMPORT_BLOCKED_ROW_QUERY_FAILED");
    }
    const parsed = dynamicImportBlockedRowSchema.safeParse(data);
    if (!parsed.success) {
      throw new Error("DYNAMIC_IMPORT_BLOCKED_ROW_RESPONSE_INVALID");
    }
    return NextResponse.json(parsed.data, { headers: privateHeaders });
  } catch (error) {
    const code = error instanceof Error ? error.message : "";
    if (code === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Alleen de beheerder met MFA kan conflictdetails bekijken." },
        { status: 403, headers: privateHeaders },
      );
    }
    if (code === "DYNAMIC_IMPORT_BLOCKED_ROW_NOT_FOUND") {
      return NextResponse.json(
        { error: "De tijdelijke conflictdetails zijn verlopen of niet beschikbaar." },
        { status: 404, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      { error: "De conflictdetails konden niet veilig worden geladen." },
      { status: 500, headers: privateHeaders },
    );
  }
}
