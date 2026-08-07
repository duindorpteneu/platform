import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";
import {
  manualPaymentRefundRequestSchema,
  manualPaymentRefundResponseSchema,
} from "@/server/payments/manual";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonStandard,
  });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = manualPaymentRefundRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Ongeldige terugbetalingsregistratie." },
        { status: 400 },
      );
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) {
      return NextResponse.json(
        { error: "Databaseverbinding ontbreekt." },
        { status: 503 },
      );
    }
    const { data, error } = await supabase
      .schema("app")
      .rpc("record_manual_payment_refund_v1", {
        p_order_id: parsed.data.orderId,
        p_payment_id: parsed.data.paymentId,
        p_amount_cents: parsed.data.amountCents,
        p_reason: parsed.data.reason,
        p_evidence_reference: parsed.data.evidenceReference,
        p_request_id: parsed.data.requestId,
      });
    if (error) {
      if (error.code === "42501") {
        return NextResponse.json(
          { error: "Geen toegang tot deze betaalcorrectie." },
          { status: 403 },
        );
      }
      if (error.code === "P0002") {
        return NextResponse.json(
          { error: "Betaling niet gevonden." },
          { status: 404 },
        );
      }
      if (error.message.includes("IDEMPOTENCY_CONFLICT")) {
        return NextResponse.json(
          {
            error:
              "Dit correctieverzoek hoort bij andere gegevens. Start opnieuw.",
          },
          { status: 409 },
        );
      }
      if (error.message.includes("PAYMENT_RECONCILIATION_OPEN")) {
        return NextResponse.json(
          {
            error:
              "Los eerst het open betaalconflict op voordat je de refund vastlegt.",
          },
          { status: 409 },
        );
      }
      if (error.message.includes("AMOUNT_MISMATCH")) {
        return NextResponse.json(
          { error: "Bedrag of pakketsnapshot is gewijzigd. Ververs de pagina." },
          { status: 409 },
        );
      }
      return NextResponse.json(
        {
          error:
            "De externe terugbetaling kon niet veilig worden vastgelegd.",
        },
        { status: 409 },
      );
    }
    const response = manualPaymentRefundResponseSchema.safeParse(data);
    if (!response.success) {
      return NextResponse.json(
        { error: "De betaalcorrectie gaf een ongeldig resultaat." },
        { status: 502 },
      );
    }
    return NextResponse.json(response.data);
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot deze betaalcorrectie." },
        { status: 403 },
      );
    }
    return NextResponse.json(
      { error: "De betaalcorrectie kon niet worden verwerkt." },
      { status: 500 },
    );
  }
}
