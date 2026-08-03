import { NextResponse } from "next/server";
import {
  parentPackageSelectionRequestSchema,
  parentPackageSelectionResponseSchema,
} from "@/lib/parent-package-contract";
import { getParentSession } from "@/server/auth/parent-session";
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
  if (guarded) {
    guarded.headers.set("Cache-Control", privateHeaders["Cache-Control"]);
    return guarded;
  }

  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = parentPackageSelectionRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return fail("Controleer het gekozen kledingpakket.", 400);
  }

  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) return fail("Oudersessie vereist.", 401);

  const { data, error } = await admin.rpc("select_parent_package_v3", {
    p_token_hash: session.tokenHash,
    p_member_season_id: parsed.data.memberSeasonId,
    p_package_revision_id: parsed.data.packageRevisionId,
    p_expected_revision: parsed.data.revision,
    p_request_id: parsed.data.requestId,
    p_correlation_id: normalizeCorrelationId(
      request.headers.get("x-correlation-id"),
    ),
  });
  if (error) {
    if (error.code === "42501") {
      if (error.message?.includes("FEATURE_DISABLED")) {
        return fail("Pakketkeuze is veilig gepauzeerd.", 503);
      }
      return fail("Geen toegang tot dit lid-seizoen.", 403);
    }
    if (error.code === "40001") {
      return fail(
        "Het pakketoverzicht is intussen gewijzigd. Vernieuw en probeer opnieuw.",
        409,
      );
    }
    if (error.code === "P0002") {
      return fail("Dit lid-seizoen bestaat niet meer.", 404);
    }
    if (error.code === "23514") {
      return fail(
        "Dit pakket kan niet meer rechtstreeks worden gekozen of gewisseld.",
        409,
      );
    }
    if (error.code === "22023") {
      return fail("De pakketkeuze is ongeldig.", 400);
    }
    return fail("Het kledingpakket kon niet veilig worden gekozen.", 500);
  }

  const output = parentPackageSelectionResponseSchema.safeParse(data);
  if (!output.success) {
    return fail("Ongeldig antwoord van de database.", 502);
  }
  return NextResponse.json(output.data, { headers: privateHeaders });
}
