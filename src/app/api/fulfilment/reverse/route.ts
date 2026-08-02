import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { fulfilmentCorrectionRequestSchema } from "@/server/operations/requests";
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
    const parsed = fulfilmentCorrectionRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Selecteer regels, doelstatus en een verplichte reden." }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const { data, error } = await supabase.schema("app").rpc("correct_fulfilment", {
      p_order_line_ids: parsed.data.orderLineIds,
      p_target_status: parsed.data.targetStatus,
      p_reason: parsed.data.reason,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot uitgiftecorrecties." }, { status: 403 });
      if (error.code === "23514") return NextResponse.json({ error: "Een geselecteerde regel is al gecorrigeerd of niet uitgegeven." }, { status: 409 });
      return NextResponse.json({ error: "De uitgiftecorrectie kon niet transactioneel worden opgeslagen." }, { status: 409 });
    }
    return NextResponse.json(data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot uitgiftecorrecties." }, { status: 403 });
    }
    return NextResponse.json({ error: "De uitgiftecorrectie kon niet worden verwerkt." }, { status: 500 });
  }
}
