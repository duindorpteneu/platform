import { NextResponse } from "next/server";
import {
  manualMemberCreateRequestSchema,
  manualMemberCreateResponseSchema,
  manualMemberPreflightSchema,
} from "@/lib/manual-member-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

function rpcInput(input: ReturnType<typeof manualMemberCreateRequestSchema.parse>) {
  return {
    p_external_id: input.externalId ?? null,
    p_first_name: input.firstName,
    p_insertion: input.insertion ?? null,
    p_last_name: input.lastName,
    p_email: input.email ?? null,
    p_date_of_birth: input.dateOfBirth ?? null,
  };
}

function databaseError(error: { code?: string; message?: string }) {
  if (error.code === "42501") {
    return NextResponse.json(
      { error: "Alleen een beheerder met MFA kan handmatig een lid toevoegen." },
      { status: 403, headers: privateHeaders },
    );
  }
  if (error.code === "23514" || error.message?.includes("ACTIVE_SEASON_REQUIRED")) {
    return NextResponse.json(
      { error: "Er is geen open actief seizoen. Activeer eerst een seizoen." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (error.message?.includes("MANUAL_MEMBER_EXTERNAL_ID_EXISTS")) {
    return NextResponse.json(
      { error: "Dit Sportlink-relatienummer hoort al bij een bestaand lid." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (error.message?.includes("MANUAL_MEMBER_DUPLICATE_CONFIRMATION_REQUIRED")) {
    return NextResponse.json(
      { error: "Controleer en bevestig eerst de mogelijke dubbele leden." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (error.message?.includes("MANUAL_MEMBER_REQUEST_REUSED")) {
    return NextResponse.json(
      { error: "Deze toevoegactie is al met andere gegevens gebruikt. Probeer opnieuw." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (error.code === "40001" || error.message?.includes("PREFLIGHT_CHANGED")) {
    return NextResponse.json(
      { error: "Het ledenbestand wijzigde tijdens de controle. Controleer mogelijke dubbelen opnieuw." },
      { status: 409, headers: privateHeaders },
    );
  }
  return NextResponse.json(
    { error: "Het lid kon niet veilig worden toegevoegd." },
    { status: 422, headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
    if (!body.ok) return body.response;
    const input = manualMemberCreateRequestSchema.safeParse(body.data);
    if (!input.success) {
      return NextResponse.json(
        { error: "Controleer de naam, e-mail, geboortedatum en maximale veldlengtes." },
        { status: 400, headers: privateHeaders },
      );
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) {
      return NextResponse.json(
        { error: "Databaseverbinding ontbreekt." },
        { status: 503, headers: privateHeaders },
      );
    }

    const preflightResult = await supabase.schema("app").rpc(
      "preflight_manual_member_create",
      rpcInput(input.data),
    );
    if (preflightResult.error) return databaseError(preflightResult.error);
    const preflight = manualMemberPreflightSchema.safeParse(preflightResult.data);
    if (!preflight.success) {
      return NextResponse.json(
        { error: "De dubbeleledencontrole gaf een ongeldig antwoord." },
        { status: 502, headers: privateHeaders },
      );
    }

    const exactExternalConflict = preflight.data.candidates.some((candidate) => (
      candidate.reasons.includes("external_id")
    ));
    if (exactExternalConflict) {
      return NextResponse.json(
        {
          error: "Dit Sportlink-relatienummer hoort al bij een bestaand lid.",
          preflight: preflight.data,
          hardConflict: true,
        },
        { status: 409, headers: privateHeaders },
      );
    }
    if (preflight.data.candidates.length > 0 && !input.data.allowPotentialDuplicate) {
      return NextResponse.json(
        {
          error: "Controleer de mogelijke dubbele leden voordat je doorgaat.",
          preflight: preflight.data,
          requiresConfirmation: true,
        },
        { status: 409, headers: privateHeaders },
      );
    }
    if (
      input.data.allowPotentialDuplicate
      && input.data.expectedFingerprint !== preflight.data.fingerprint
    ) {
      return NextResponse.json(
        {
          error: "De mogelijke dubbelen zijn gewijzigd. Controleer ze opnieuw.",
          preflight: preflight.data,
          requiresConfirmation: true,
        },
        { status: 409, headers: privateHeaders },
      );
    }

    const createResult = await supabase.schema("app").rpc("create_manual_member", {
      ...rpcInput(input.data),
      p_gender: input.data.gender,
      p_team: input.data.team ?? null,
      p_client_request_id: input.data.clientRequestId,
      p_expected_fingerprint: preflight.data.fingerprint,
      p_allow_potential_duplicate: input.data.allowPotentialDuplicate,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (createResult.error) return databaseError(createResult.error);
    const created = manualMemberCreateResponseSchema.safeParse(createResult.data);
    if (!created.success) {
      return NextResponse.json(
        { error: "De database gaf een ongeldig resultaat terug." },
        { status: 502, headers: privateHeaders },
      );
    }
    return NextResponse.json(created.data, { status: 201, headers: privateHeaders });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Alleen een beheerder kan handmatig een lid toevoegen." },
        { status: 403, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      { error: "Het lid kon niet worden verwerkt." },
      { status: 500, headers: privateHeaders },
    );
  }
}
