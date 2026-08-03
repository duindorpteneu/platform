import { NextResponse } from "next/server";
import { z } from "zod";
import { requireStaffSessionBinding } from "@/server/auth/staff";
import { qrManagementRequestSchema } from "@/server/operations/requests";
import {
  deriveQrLocator,
  generateQrDerivationNonce,
  hashQrLocator,
  qrKeyVersion,
  qrPepperFingerprint,
} from "@/server/qr/tokens";
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

const contextSchema = z.object({
  orderId: z.string().uuid(),
  currentGeneration: z.number().int().positive().nullable(),
  nextGeneration: z.number().int().positive(),
  suspended: z.boolean(),
  businessEligible: z.boolean(),
}).strict();

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
    const parsed = qrManagementRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Vul een geldige verplichte reden in." },
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
    const { data: contextData, error: contextError } = await admin
      .schema("app")
      .rpc("get_order_qr_management_context_v2", {
        p_actor_id: staff.userId,
        p_order_id: parsed.data.orderId,
        p_staff_session_hash: staff.sessionTokenHash,
      });
    const context = contextSchema.safeParse(contextData);
    if (contextError?.code === "42501") {
      return NextResponse.json(
        { error: "Geen toegang tot QR-beheer." },
        { status: 403, headers: privateHeaders },
      );
    }
    if (contextError?.code === "P0002") {
      return NextResponse.json(
        { error: "Bestelling niet gevonden." },
        { status: 404, headers: privateHeaders },
      );
    }
    if (contextError || !context.success) {
      return NextResponse.json(
        { error: "De actuele QR-status kon niet worden bepaald." },
        { status: 503, headers: privateHeaders },
      );
    }

    const keyVersion = qrKeyVersion();
    const nonce = parsed.data.action === "rotate"
      ? generateQrDerivationNonce()
      : null;
    const locator = parsed.data.action === "rotate"
      ? deriveQrLocator({
        generation: context.data.nextGeneration,
        keyVersion,
        nonce: nonce!,
        orderId: parsed.data.orderId,
      })
      : null;
    const { data, error } = await admin
      .schema("app")
      .rpc("manage_order_qr_locator_v2", {
        p_action: parsed.data.action,
        p_actor_id: staff.userId,
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
        p_expected_generation: context.data.nextGeneration - 1,
        p_key_version: locator ? keyVersion : null,
        p_derivation_nonce: nonce,
        p_locator_hash: locator ? hashQrLocator(locator) : null,
        p_order_id: parsed.data.orderId,
        p_pepper_fingerprint: locator ? qrPepperFingerprint() : null,
        p_reason: parsed.data.reason,
        p_request_id: parsed.data.requestId,
        p_staff_session_hash: staff.sessionTokenHash,
      });
    if (error) {
      if (error.code === "42501") {
        return NextResponse.json(
          { error: "Geen toegang tot QR-beheer." },
          { status: 403, headers: privateHeaders },
        );
      }
      if (error.code === "P0002") {
        return NextResponse.json(
          { error: "Deze bestelling heeft geen QR-identiteit." },
          { status: 404, headers: privateHeaders },
        );
      }
      if (error.code === "40001") {
        return NextResponse.json(
          { error: "De QR-code is al gewijzigd. Vernieuw de pagina." },
          { status: 409, headers: privateHeaders },
        );
      }
      if (error.code === "23505") {
        return NextResponse.json(
          { error: "Deze QR-actie is al met andere invoer verwerkt." },
          { status: 409, headers: privateHeaders },
        );
      }
      return NextResponse.json(
        { error: "De QR-actie kon niet veilig worden opgeslagen." },
        { status: 503, headers: privateHeaders },
      );
    }
    return NextResponse.json(data, { headers: privateHeaders });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "QR_TOKEN_KEY_VERSION_UNAVAILABLE"
    ) {
      return NextResponse.json(
        { error: "QR-sleutelconfiguratie is niet beschikbaar." },
        { status: 503, headers: privateHeaders },
      );
    }
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot QR-beheer." },
        { status: 403, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      { error: "De QR-actie kon niet worden verwerkt." },
      { status: 500, headers: privateHeaders },
    );
  }
}
