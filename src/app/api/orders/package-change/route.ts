import { NextResponse } from "next/server";
import {
  packageChangeRequestSchema,
  packageChangeResponseSchema,
} from "@/lib/package-change-contract";
import { requireStaffSessionBinding } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { startMollieRefund } from "@/server/payments/mollie-service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = {
  "Cache-Control": "private, no-store, max-age=0",
};

function fail(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    { status, headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = packageChangeRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return fail("Controleer pakketwijziging, reden en bevestiging.", 400);
  }
  try {
    const staff = await requireStaffSessionBinding(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const correlationId = normalizeCorrelationId(
      request.headers.get("x-correlation-id"),
    );
    const result = parsed.data.action === "preflight"
      ? await supabase.schema("app").rpc(
        "preflight_package_change_v2",
        {
          p_order_id: parsed.data.orderId,
          p_target_revision_id:
            parsed.data.targetPackageRevisionId,
          p_reason: parsed.data.reason,
          p_request_id: parsed.data.requestId,
          p_correlation_id: correlationId,
        },
      )
      : await supabase.schema("app").rpc(
        "apply_package_change_v2",
        {
          p_request_id: parsed.data.requestId,
          p_expected_revision: parsed.data.revision,
          p_confirmation: parsed.data.confirmation,
          p_correlation_id: correlationId,
        },
      );
    if (result.error) {
      if (result.error.code === "42501") {
        return fail(
          "Alleen een beheerder met MFA kan pakketten corrigeren.",
          403,
        );
      }
      if (result.error.code === "40001") {
        return fail(
          "Betaling, voorraad of pakket is intussen gewijzigd. Controleer opnieuw.",
          409,
        );
      }
      if (result.error.code === "23505") {
        return fail(
          "Dit verzoek-ID is al voor een andere wijziging gebruikt.",
          409,
        );
      }
      if (result.error.code === "P0002") {
        return fail("Order, pakket of verzoek bestaat niet meer.", 404);
      }
      if (result.error.code === "23514") {
        return fail(
          "Los eerst betaling, uitgifte of reconciliatie aantoonbaar op.",
          409,
        );
      }
      if (result.error.code === "22023") {
        return fail("De pakketwijziging of bevestiging is ongeldig.", 400);
      }
      return fail(
        "De pakketwijziging kon niet veilig worden verwerkt.",
        500,
      );
    }
    const output = packageChangeResponseSchema.safeParse(result.data);
    if (!output.success) {
      return fail("Ongeldig antwoord van de database.", 502);
    }
    if (parsed.data.action === "apply" && output.data.result) {
      const admin = getSupabaseAdminClient();
      if (admin) {
        for (const refund of output.data.result.refunds) {
          if (refund.method !== "mollie") continue;
          try {
            await startMollieRefund({
              refundId: refund.refundId,
              requestId: refund.refundId,
              actorUserId: staff.userId,
              staffSessionHash: staff.sessionTokenHash,
              correlationId,
            }, { database: admin });
          } catch {
            return fail(
              "Het pakket is gecorrigeerd, maar Mollie kon de duurzame refund nog niet starten. Probeer hetzelfde verzoek opnieuw of gebruik Betalingen.",
              503,
            );
          }
        }
      }
    }
    return NextResponse.json(output.data, {
      headers: privateHeaders,
    });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return fail(
        "Alleen een beheerder met MFA kan pakketten corrigeren.",
        403,
      );
    }
    return fail(
      "De pakketwijziging kon niet veilig worden verwerkt.",
      500,
    );
  }
}
