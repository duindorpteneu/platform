import { NextResponse } from "next/server";
import { fulfilmentCommitResponseSchema } from "@/lib/fulfilment-contract";
import { requireStaffSessionBinding } from "@/server/auth/staff";
import {
  fulfilmentCommitRequestSchema,
  hashQrScanGrant,
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

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonStandard,
  });
  if (guarded) return guarded;
  try {
    const staff = await requireStaffSessionBinding(["beheerder", "uitgifte"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = fulfilmentCommitRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Ongeldige uitgifteselectie." },
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
    const { data, error } = await admin
      .schema("app")
      .rpc("commit_fulfilment_v3", {
        p_actor_id: staff.userId,
        p_correlation_id: normalizeCorrelationId(
          request.headers.get("x-correlation-id"),
        ),
        p_grant_hash: hashQrScanGrant(parsed.data.scanGrant),
        p_order_line_ids: parsed.data.orderLineIds,
        p_request_id: parsed.data.requestId,
        p_staff_session_hash: staff.sessionTokenHash,
      });
    if (error) {
      if (error.code === "42501") {
        return NextResponse.json(
          { error: "Geen toegang tot uitgifte." },
          { status: 403, headers: privateHeaders },
        );
      }
      if (error.code === "23505") {
        return NextResponse.json(
          { error: "Deze uitgifteactie conflicteert met een eerdere poging." },
          { status: 409, headers: privateHeaders },
        );
      }
      if (["22023", "23503", "23514"].includes(error.code ?? "")) {
        return NextResponse.json(
          {
            error: "De uitgifte is geweigerd; scan opnieuw en controleer de selectie.",
          },
          { status: 409, headers: privateHeaders },
        );
      }
      return NextResponse.json(
        { error: "De uitgifte kon niet transactioneel worden opgeslagen." },
        { status: 503, headers: privateHeaders },
      );
    }
    const response = fulfilmentCommitResponseSchema.safeParse(data);
    if (!response.success) {
      return NextResponse.json(
        { error: "De uitgifte gaf een ongeldig databaseantwoord." },
        { status: 502, headers: privateHeaders },
      );
    }
    if (response.data.status !== "completed") {
      return NextResponse.json(
        {
          error: response.data.status === "blocked"
            ? "De afhaallocatie is niet correct ingesteld."
            : "De scan is verlopen of niet meer actueel. Scan opnieuw.",
        },
        { status: 409, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      response.data,
      { status: response.data.reused ? 200 : 201, headers: privateHeaders },
    );
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "QR_TOKEN_KEY_VERSION_UNAVAILABLE"
    ) {
      return NextResponse.json(
        { error: "De scan is verlopen of niet meer actueel. Scan opnieuw." },
        { status: 409, headers: privateHeaders },
      );
    }
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot uitgifte." },
        { status: 403, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      { error: "De uitgifte kon niet worden verwerkt." },
      { status: 500, headers: privateHeaders },
    );
  }
}
