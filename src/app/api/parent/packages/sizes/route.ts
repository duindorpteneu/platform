import { NextResponse } from "next/server";
import {
  parentPackageSizesRequestSchema,
  parentPackageSizesResponseSchema,
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
    body: BODY_POLICIES.jsonMedium,
  });
  if (guarded) {
    guarded.headers.set("Cache-Control", privateHeaders["Cache-Control"]);
    return guarded;
  }

  const body = await readJsonRequest(request, BODY_POLICIES.jsonMedium);
  if (!body.ok) return body.response;
  const parsed = parentPackageSizesRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return fail("Controleer alle gekozen maten.", 400);
  }

  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) return fail("Inloggen vereist.", 401);

  const { data, error } = await admin.rpc(
      "confirm_parent_package_sizes_v5",
    {
      p_token_hash: session.tokenHash,
      p_member_season_id: parsed.data.memberSeasonId,
      p_selections: parsed.data.selections,
      p_expected_revision: parsed.data.revision,
      p_request_id: parsed.data.requestId,
      p_correlation_id: normalizeCorrelationId(
        request.headers.get("x-correlation-id"),
      ),
    },
  );
  if (error) {
    if (error.code === "42501") {
      if (error.message?.includes("FEATURE_DISABLED")) {
        return fail("Maatbevestiging is veilig gepauzeerd.", 503);
      }
      return fail("Geen toegang tot dit lid.", 403);
    }
    if (error.code === "40001") {
      return fail(
        "De maten zijn intussen gewijzigd. Vernieuw en controleer opnieuw.",
        409,
      );
    }
    if (error.code === "23505") {
      return fail(
        "Deze bevestiging hoort al bij andere maatkeuzes. Probeer opnieuw.",
        409,
      );
    }
    if (error.code === "P0002") {
      return fail("Dit pakket bestaat niet meer.", 404);
    }
    if (error.code === "23514") {
      return fail(
        "Een gereserveerd of uitgegeven product kan niet rechtstreeks worden gewijzigd.",
        409,
      );
    }
    if (error.code === "22023") {
      return fail("De maten zijn onvolledig of niet meer geldig.", 400);
    }
    return fail("De maten konden niet veilig worden bevestigd.", 500);
  }

  const output = parentPackageSizesResponseSchema.safeParse(data);
  if (!output.success) {
    return fail("Ongeldig antwoord van de database.", 502);
  }
  return NextResponse.json(output.data, { headers: privateHeaders });
}
