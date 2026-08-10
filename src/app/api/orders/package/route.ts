import { NextResponse } from "next/server";
import {
  staffPackageSelectionRequestSchema,
  staffPackageSelectionResponseSchema,
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
  const parsed = staffPackageSelectionRequestSchema.safeParse(body.data);
  if (!parsed.success) return fail("Controleer de pakketkeuze en reden.", 400);

  try {
    await requireStaffRole(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const { data, error } = await supabase.schema("app").rpc(
      "select_member_package_v3",
      {
        p_member_season_id: parsed.data.memberSeasonId,
        p_package_revision_id: parsed.data.packageRevisionId,
        p_expected_revision: parsed.data.revision,
        p_reason: parsed.data.reason,
        p_request_id: parsed.data.requestId,
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
      },
    );
    if (error) {
      if (error.code === "42501") return fail("Alleen een beheerder met MFA kan een pakket kiezen.", 403);
      if (error.code === "40001") return fail("Het pakketoverzicht is intussen gewijzigd.", 409);
      if (error.code === "23505") return fail("Dit verzoek-ID is al voor een andere pakketkeuze gebruikt.", 409);
      if (error.code === "P0002") return fail("Dit lid-seizoen bestaat niet meer.", 404);
      if (error.code === "23514") return fail("Dit pakket kan niet rechtstreeks worden gewijzigd.", 409);
      if (error.code === "22023") return fail("De pakketkeuze is ongeldig.", 400);
      return fail("Het pakket kon niet veilig worden gekozen.", 500);
    }
    const output = staffPackageSelectionResponseSchema.safeParse(data);
    if (!output.success) return fail("Ongeldig antwoord van de database.", 502);
    return NextResponse.json(output.data, { headers: privateHeaders });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return fail("Alleen een beheerder met MFA kan een pakket kiezen.", 403);
    }
    return fail("Het pakket kon niet veilig worden verwerkt.", 500);
  }
}
