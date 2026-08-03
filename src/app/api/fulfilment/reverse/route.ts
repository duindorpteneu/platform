import { NextResponse } from "next/server";
import { requireStaffSessionBinding } from "@/server/auth/staff";
import { fulfilmentCorrectionRequestSchema } from "@/server/operations/requests";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonStandard,
  });
  if (guarded) return guarded;
  try {
    const staff = await requireStaffSessionBinding([
      "beheerder",
      "kledingcommissie",
    ]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = fulfilmentCorrectionRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Selecteer regels, doelstatus en een verplichte reden." },
        { status: 400, headers: privateHeaders },
      );
    }
    const admin = getSupabaseAdminClient();
    if (!admin) {
      return NextResponse.json(
        { error: "Databaseverbinding ontbreekt." },
        { status: 503, headers: privateHeaders },
      );
    }
    const { data, error } = await admin
      .schema("app")
      .rpc("correct_fulfilment_v3", {
        p_actor_id: staff.userId,
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
        p_order_line_ids: parsed.data.orderLineIds,
        p_reason: parsed.data.reason,
        p_request_id: parsed.data.requestId,
        p_staff_session_hash: staff.sessionTokenHash,
        p_target_status: parsed.data.targetStatus,
      });
    if (error) {
      if (error.code === "42501") {
        return NextResponse.json(
          { error: "Geen toegang tot uitgiftecorrecties." },
          { status: 403, headers: privateHeaders },
        );
      }
      if (error.code === "23505") {
        return NextResponse.json(
          { error: "Deze correctiepoging conflicteert met een eerdere actie." },
          { status: 409, headers: privateHeaders },
        );
      }
      if (error.code === "23514") {
        return NextResponse.json(
          { error: "Een geselecteerde regel is al gecorrigeerd of niet uitgegeven." },
          { status: 409, headers: privateHeaders },
        );
      }
      return NextResponse.json(
        { error: "De uitgiftecorrectie kon niet transactioneel worden opgeslagen." },
        { status: 503, headers: privateHeaders },
      );
    }
    return NextResponse.json(data, { headers: privateHeaders });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot uitgiftecorrecties." },
        { status: 403, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      { error: "De uitgiftecorrectie kon niet worden verwerkt." },
      { status: 500, headers: privateHeaders },
    );
  }
}
