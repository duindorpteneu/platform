import { NextResponse } from "next/server";
import { fulfilmentExchangeResponseSchema } from "@/lib/fulfilment-contract";
import { requireStaffSessionBinding } from "@/server/auth/staff";
import {
  deriveQrScanGrant,
  fulfilmentExchangeRequestSchema,
  hashQrLocator,
  hashQrScanGrant,
  qrKeyVersion,
} from "@/server/qr/tokens";
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
    const parsed = fulfilmentExchangeRequestSchema.safeParse(body.data);
    if (!parsed.success) {
      return NextResponse.json(
        { status: "invalid" },
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
    let locatorHash: string;
    try {
      locatorHash = hashQrLocator(parsed.data.locator);
    } catch (error) {
      if (
        error instanceof Error
        && error.message === "QR_TOKEN_KEY_VERSION_UNAVAILABLE"
      ) {
        return NextResponse.json(
          { status: "invalid" },
          { headers: privateHeaders },
        );
      }
      throw error;
    }
    const keyVersion = qrKeyVersion();
    const scanGrant = deriveQrScanGrant({
      actorId: staff.userId,
      locator: parsed.data.locator,
      requestId: parsed.data.requestId,
      staffSessionHash: staff.sessionTokenHash,
    });
    const { data, error } = await admin
      .schema("app")
      .rpc("exchange_order_qr_locator_v2", {
        p_actor_id: staff.userId,
        p_grant_hash: hashQrScanGrant(scanGrant),
        p_grant_key_version: keyVersion,
        p_locator_hash: locatorHash,
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
      if (error.code === "P0001") {
        return NextResponse.json(
          { error: "Te veel scanpogingen. Probeer het zo opnieuw." },
          { status: 429, headers: privateHeaders },
        );
      }
      return NextResponse.json(
        { error: "De QR-code kon niet veilig worden gecontroleerd." },
        { status: 503, headers: privateHeaders },
      );
    }
    const response = fulfilmentExchangeResponseSchema.safeParse(
      data && typeof data === "object" && "status" in data
        ? data.status === "found"
          ? { ...data, scanGrant }
          : data
        : data,
    );
    if (!response.success) {
      return NextResponse.json(
        { error: "De QR-code gaf een ongeldig databaseantwoord." },
        { status: 502, headers: privateHeaders },
      );
    }
    return NextResponse.json(response.data, { headers: privateHeaders });
  } catch (error) {
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
      { error: "De QR-code kon niet worden verwerkt." },
      { status: 500, headers: privateHeaders },
    );
  }
}
