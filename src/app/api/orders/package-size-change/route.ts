import { NextResponse } from "next/server";
import {
  packageSizeChangeResolutionRequestSchema,
  packageSizeChangeResolutionResponseSchema,
} from "@/lib/parent-package-contract";
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
  const parsed = packageSizeChangeResolutionRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return fail("Controleer de beslissing, concrete maat en reden.", 400);
  }

  try {
    await requireStaffRole(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const { data, error } = await supabase.schema("app").rpc(
      "resolve_package_size_change_v3",
      {
        p_request_id: parsed.data.requestId,
        p_decision: parsed.data.decision,
        p_approved_variant_id: parsed.data.approvedVariantId,
        p_reason: parsed.data.reason,
        p_expected_revision: parsed.data.revision,
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
      },
    );
    if (error) {
      if (error.code === "42501") return fail("Alleen een beheerder met MFA kan dit verzoek beslissen.", 403);
      if (error.code === "40001") return fail("Het maatverzoek is intussen gewijzigd of al beslist.", 409);
      if (error.code === "P0002") return fail("Dit maatverzoek bestaat niet meer.", 404);
      if (error.code === "23514") return fail("Deze reservering of uitgifte kan niet veilig worden gewijzigd.", 409);
      if (error.code === "22023") return fail("De gekozen maat of beslissing is ongeldig.", 400);
      return fail("Het maatverzoek kon niet veilig worden verwerkt.", 500);
    }
    const output = packageSizeChangeResolutionResponseSchema.safeParse(data);
    if (!output.success) return fail("Ongeldig antwoord van de database.", 502);
    return NextResponse.json(output.data, { headers: privateHeaders });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return fail(
        "Alleen een beheerder met MFA kan dit verzoek beslissen.",
        403,
      );
    }
    return fail("Het maatverzoek kon niet veilig worden verwerkt.", 500);
  }
}
