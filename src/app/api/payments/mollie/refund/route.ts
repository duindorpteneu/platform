import { NextResponse } from "next/server";
import { mollieRefundRequestSchema } from "@/lib/mollie-contract";
import { requireStaffRole } from "@/server/auth/staff";
import {
  getMollieRuntimeConfig,
  hasTrustedPaymentOrigin,
  MollieServiceError,
  startMollieRefund,
} from "@/server/payments/mollie-service";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonTiny });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    const config = getMollieRuntimeConfig();
    if (!hasTrustedPaymentOrigin(request, config.appBaseUrl)) {
      return NextResponse.json({ error: "Ongeldige aanvraagbron." }, { status: 403 });
    }
    const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
    if (!body.ok) return body.response;
    const parsed = mollieRefundRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return NextResponse.json({ error: "Ongeldig terugbetalingsverzoek." }, { status: 400 });
    }
    const admin = getSupabaseAdminClient();
    if (!admin) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });
    const result = await startMollieRefund({
      ...parsed.data,
      correlationId: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    }, { database: admin, config });
    return NextResponse.json(result, {
      headers: { "Cache-Control": "private, no-store, max-age=0" },
    });
  } catch (error) {
    if (error instanceof MollieServiceError) {
      return NextResponse.json(
        { error: error.retryable
          ? "Mollie is tijdelijk niet bereikbaar; probeer dezelfde refund opnieuw."
          : "De Mollie-refund kon niet veilig worden gestart." },
        { status: error.retryable ? 503 : 409 },
      );
    }
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Alleen een beheerder met MFA kan terugbetalen." }, { status: 403 });
    }
    return NextResponse.json({ error: "De terugbetaling kon niet worden verwerkt." }, { status: 500 });
  }
}
