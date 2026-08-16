import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import {
  memberPackageBulkRequestSchema,
  memberPackageBulkResponseSchema,
} from "@/lib/member-package-bulk-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  createMemberPackagePreviewToken,
  verifyMemberPackagePreviewToken,
} from "@/server/security/member-package-preview-token";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

function fail(error: string, status: number) {
  return NextResponse.json({ error }, { status, headers: privateHeaders });
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = memberPackageBulkRequestSchema.safeParse(body.data);
  if (!parsed.success) return fail("Controleer de pakketactie, selectie en beheerreden.", 400);

  try {
    await requireStaffRole(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const input = parsed.data;
    const pepper = getServerEnv().PARENT_TOKEN_PEPPER;
    if (!pepper) return fail("Beveiligingsconfiguratie ontbreekt.", 503);
    let expectedSeasonId: string | undefined;
    let expectedRevision: string | undefined;

    if (input.commit) {
      try {
        const token = verifyMemberPackagePreviewToken(input.previewToken ?? "", pepper);
        const ids = [...input.memberSeasonIds].sort();
        if (
          token.action !== input.action
          || token.scope !== input.scope
          || token.packageRevisionId !== input.packageRevisionId
          || token.reason !== input.reason
          || token.memberSeasonIds.length !== ids.length
          || token.memberSeasonIds.some((id, index) => id !== ids[index])
        ) throw new Error("MEMBER_PACKAGE_PREVIEW_TOKEN_MISMATCH");
        expectedSeasonId = token.seasonId;
        expectedRevision = token.revision;
      } catch {
        return fail("De voorcontrole is verlopen of past niet meer bij deze pakketactie. Controleer opnieuw.", 409);
      }
    }

    const { data, error } = input.commit
      ? await supabase.schema("app").rpc("apply_member_package_bulk_v1", {
        p_action: input.action,
        p_scope: input.scope,
        p_member_season_ids: input.memberSeasonIds,
        p_package_revision_id: input.packageRevisionId,
        p_expected_season_id: expectedSeasonId!,
        p_expected_revision: expectedRevision!,
        p_reason: input.reason,
        p_request_id: input.requestId,
        p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
      })
      : await supabase.schema("app").rpc("preview_member_package_bulk_v1", {
        p_action: input.action,
        p_scope: input.scope,
        p_member_season_ids: input.memberSeasonIds,
        p_package_revision_id: input.packageRevisionId,
      });

    if (error) {
      if (error.code === "42501") return fail("Alleen een beheerder met MFA kan pakketten toewijzen of verwijderen.", 403);
      if (error.code === "40001") return fail("Leden, maten of bestellingen zijn sinds de voorcontrole gewijzigd. Controleer opnieuw.", 409);
      if (error.code === "23505") return fail("Dit verzoek-ID is al voor een andere pakketactie gebruikt.", 409);
      if (error.code === "23514") return fail("Het seizoen of pakket is niet meer actief, of de actie is financieel/logistiek geblokkeerd.", 409);
      if (error.code === "22023") return fail("De pakketactie of selectie is ongeldig.", 400);
      return fail("De pakketactie kon niet veilig worden verwerkt.", 422);
    }

    let responseData = data;
    if (!input.commit && responseData && typeof responseData === "object" && !Array.isArray(responseData)) {
      const { revision, ...visible } = responseData as Record<string, unknown>;
      if (typeof revision !== "string" || !/^[0-9a-f]{64}$/.test(revision) || typeof visible.seasonId !== "string") {
        return fail("Ongeldig antwoord van de database.", 502);
      }
      responseData = {
        ...visible,
        committed: false,
        previewToken: createMemberPackagePreviewToken({
          action: input.action,
          scope: input.scope,
          memberSeasonIds: input.memberSeasonIds,
          packageRevisionId: input.packageRevisionId,
          reason: input.reason,
          seasonId: visible.seasonId,
          revision,
        }, pepper),
      };
    }
    const response = memberPackageBulkResponseSchema.safeParse(responseData);
    if (!response.success) return fail("Ongeldig antwoord van de database.", 502);
    return NextResponse.json(response.data, { headers: privateHeaders });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return fail("Alleen een beheerder met MFA kan pakketten toewijzen of verwijderen.", 403);
    }
    return fail("De pakketactie kon niet worden verwerkt.", 500);
  }
}
