import { NextResponse } from "next/server";
import {
  looseOrderLineRemovalRequestSchema,
  looseOrderLineRemovalResponseSchema,
} from "@/lib/loose-order-line-removal-contract";
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

function fail(error: string, status: number) {
  return NextResponse.json({ error }, { status, headers: privateHeaders });
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = looseOrderLineRemovalRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return fail("Kies een losse regel en geef een korte reden op.", 400);
  }

  try {
    await requireStaffRole(["beheerder"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return fail("Databaseverbinding ontbreekt.", 503);
    const { data, error } = await supabase.schema("app").rpc(
      "remove_loose_order_line_v1",
      {
        p_order_line_id: parsed.data.orderLineId,
        p_reason: parsed.data.reason,
        p_request_id: parsed.data.requestId,
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
      },
    );
    if (error) {
      if (error.code === "42501") {
        return fail("Alleen een beheerder met MFA kan een losse regel verwijderen.", 403);
      }
      if (error.code === "P0002") {
        return fail("Deze orderregel bestaat niet meer.", 404);
      }
      if (error.code === "23505") {
        return fail("Dit verzoek-ID is al voor een andere actie gebruikt.", 409);
      }
      if (error.code === "23514") {
        return fail(
          "Alleen een nog niet gereserveerd los artikel kan hier worden verwijderd.",
          409,
        );
      }
      if (error.code === "22023") {
        return fail("Controleer de regel en reden.", 400);
      }
      return fail("De losse regel kon niet veilig worden verwijderd.", 500);
    }
    const output = looseOrderLineRemovalResponseSchema.safeParse(data);
    if (!output.success) return fail("Ongeldig antwoord van de database.", 502);
    return NextResponse.json(output.data, { headers: privateHeaders });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return fail("Alleen een beheerder met MFA kan een losse regel verwijderen.", 403);
    }
    return fail("De losse regel kon niet veilig worden verwijderd.", 500);
  }
}
