import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { inventoryLegacyAllocationResolutionSchema, inventoryLegacyAssignmentSchema } from "@/server/stock/requests";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    await requireStaffRole(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("get_inventory_reconciliation_workspace");
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met AAL2 zien reconciliatie." }, { status: 403 });
      return NextResponse.json({ error: "Reconciliatie kon niet worden geladen." }, { status: 503 });
    }
    return NextResponse.json(data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot voorraadreconciliatie." }, { status: 403 });
    }
    return NextResponse.json({ error: "Reconciliatie kon niet worden verwerkt." }, { status: 500 });
  }
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;

  try {
    await requireStaffRole(["beheerder"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const assignment = inventoryLegacyAssignmentSchema.safeParse(body.data);
    const resolution = inventoryLegacyAllocationResolutionSchema.safeParse(body.data);
    if (!assignment.success && !resolution.success) {
      return NextResponse.json({ error: "Ongeldige geaudite reconciliatieactie." }, { status: 400 });
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    let response;
    if (assignment.success) {
      response = await supabase.schema("app").rpc("assign_legacy_inventory_balance", {
        p_reconciliation_id: assignment.data.reconciliationId,
        p_season_id: assignment.data.seasonId,
        p_quantity: assignment.data.quantity,
        p_reason: assignment.data.reason,
        p_request_id: assignment.data.requestId,
        p_correlation_id: assignment.data.correlationId ?? null,
      });
    } else if (resolution.success) {
      response = await supabase.schema("app").rpc("resolve_legacy_inventory_allocation", {
        p_allocation_id: resolution.data.allocationId,
        p_decision: resolution.data.decision,
        p_reason: resolution.data.reason,
        p_request_id: resolution.data.requestId,
        p_correlation_id: resolution.data.correlationId ?? null,
      });
    } else {
      return NextResponse.json({ error: "Ongeldige geaudite reconciliatieactie." }, { status: 400 });
    }
    if (response.error) {
      if (response.error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met AAL2 mogen reconciliëren." }, { status: 403 });
      if (response.error.code === "P0002") return NextResponse.json({ error: "Reconciliatieregel niet gevonden." }, { status: 404 });
      return NextResponse.json({ error: "De reconciliatie is geweigerd; vernieuw de actuele tellingen." }, { status: 409 });
    }
    return NextResponse.json(response.data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot voorraadreconciliatie." }, { status: 403 });
    }
    return NextResponse.json({ error: "Reconciliatie kon niet worden verwerkt." }, { status: 500 });
  }
}
