import { NextResponse } from "next/server";
import {
  memberFamilyEmailPreflightRequestSchema,
  memberFamilyEmailPreflightResponseSchema,
} from "@/lib/member-profile-contract";
import { requireStaffRole } from "@/server/auth/staff";
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
    const parsed = memberFamilyEmailPreflightRequestSchema.safeParse(body.data);
    if (!parsed.success) return fail("Vul een geldig nieuw e-mailadres in.", 400);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const { data, error } = await supabase.schema("app").rpc(
      "preview_member_family_email_transfer_v1",
      {
        p_member_id: parsed.data.memberId,
        p_member_season_id: parsed.data.memberSeasonId,
        p_new_email: parsed.data.email,
        p_expected_profile_revision: parsed.data.revision,
      },
    );
    if (error) {
      if (error.code === "42501") return fail("Alleen een beheerder met MFA kan persoonsgegevens wijzigen.", 403);
      if (error.code === "P0002") return fail("Dit lid of lid-seizoen bestaat niet meer.", 404);
      if (error.code === "40001") return fail("De leden- of portaltoegang is intussen gewijzigd. Vernieuw en probeer opnieuw.", 409);
      if (error.code === "22023") return fail("Het nieuwe e-mailadres is niet geldig.", 400);
      return fail("De gezinsbrede wijziging kon niet veilig worden gecontroleerd.", 422);
    }
    const result = memberFamilyEmailPreflightResponseSchema.safeParse(data);
    if (!result.success) return fail("Ongeldig antwoord van de database.", 502);
    if (result.data.blockedCount > 0) {
      return fail("De portaltoegang bevat een conflict. Beheer eerst de oudertoegang afzonderlijk.", 409);
    }
    return NextResponse.json(result.data, { headers: privateHeaders });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return fail("Alleen een beheerder kan persoonsgegevens wijzigen.", 403);
    }
    return fail("De gezinsbrede wijziging kon niet worden gecontroleerd.", 500);
  }
}
