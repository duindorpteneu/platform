import { NextResponse } from "next/server";
import {
  memberProfileUpdateRequestSchema,
  memberProfileUpdateResponseSchema,
} from "@/lib/member-profile-contract";
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
  return NextResponse.json({ error: message }, { status, headers: privateHeaders });
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
    if (!body.ok) return body.response;
    const parsed = memberProfileUpdateRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return fail("Controleer naam, e-mail, geboortedatum, geslacht, team en reden.", 400);
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const { data, error } = await supabase.schema("app").rpc("update_member_profile_v2", {
      p_member_id: parsed.data.memberId,
      p_member_season_id: parsed.data.memberSeasonId,
      p_first_name: parsed.data.firstName,
      p_insertion: parsed.data.insertion,
      p_last_name: parsed.data.lastName,
      p_email: parsed.data.email,
      p_date_of_birth: parsed.data.dateOfBirth,
      p_gender: parsed.data.gender,
      p_team: parsed.data.team,
      p_expected_revision: parsed.data.revision,
      p_expected_family_revision: parsed.data.familyRevision ?? null,
      p_reason: parsed.data.reason,
      p_request_id: parsed.data.requestId,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (error) {
      if (error.code === "42501") return fail("Alleen een beheerder met MFA kan persoonsgegevens wijzigen.", 403);
      if (error.code === "P0002") return fail("Dit lid of lid-seizoen bestaat niet meer.", 404);
      if (error.code === "40001") return fail("De leden- of portaltoegang is intussen gewijzigd. Voer de controle opnieuw uit.", 409);
      if (error.code === "22023") return fail("De lidgegevens zijn niet geldig voor dit seizoen.", 400);
      if (error.code === "23514") return fail("De gezinsbrede e-mailwijziging kan niet veilig worden uitgevoerd.", 409);
      return fail("De lidgegevens konden niet veilig worden opgeslagen.", 422);
    }
    const result = memberProfileUpdateResponseSchema.safeParse(data);
    if (!result.success) return fail("Ongeldig antwoord van de database.", 502);
    return NextResponse.json({ member: result.data }, { headers: privateHeaders });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return fail("Alleen een beheerder kan persoonsgegevens wijzigen.", 403);
    }
    return fail("De lidgegevens konden niet worden verwerkt.", 500);
  }
}
