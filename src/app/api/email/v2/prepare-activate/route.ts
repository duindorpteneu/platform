import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { prepareAndActivateMailV2RequestSchema } from "@/lib/mail-v2-contract";
import { prepareAndActivateMailV2 } from "@/server/email/mail-v2-bootstrap";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const noStore = { "Cache-Control": "no-store" };

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    appBaseUrl: getServerEnv().APP_BASE_URL,
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = prepareAndActivateMailV2RequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Bevestig de activatie met een geldige reden." },
      { status: 400, headers: noStore },
    );
  }
  try {
    const result = await prepareAndActivateMailV2(
      { reason: parsed.data.reason },
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen Mail-v2 gereedmaken." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "Een template is intussen gewijzigd. Vernieuw en probeer opnieuw; reeds gepubliceerde templates blijven veilig behouden." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "Voor minstens één berichttype ontbreekt een concepttemplate." },
          { status: 422, headers: noStore },
        );
      }
      if (result.error.code === "22023" || result.error.code === "23514") {
        return NextResponse.json(
          { error: "Mail-v2 is nog niet volledig gereed. Controleer templates, branding en de getoonde preflight." },
          { status: 422, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De ontbrekende templates konden niet veilig worden gepubliceerd." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Geen toegang tot Mail-v2-activatie." },
        { status: 403, headers: noStore },
      );
    }
    if (error instanceof Error && error.message.startsWith("MAIL_V2_")) {
      return NextResponse.json(
        { error: "Een concepttemplate bevat ongeldige of onveilige inhoud." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Mail-v2-activatie is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
