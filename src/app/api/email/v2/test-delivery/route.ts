import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { sendMailV2TestRequestSchema } from "@/lib/mail-v2-contract";
import { sendMailV2TestDelivery } from "@/server/email/mail-v2-test-delivery";
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
  const environment = getServerEnv();
  const guarded = guardBrowserMutation(request, {
    appBaseUrl: environment.APP_BASE_URL,
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = sendMailV2TestRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de gekozen template en aanvraagidentiteit." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const result = await sendMailV2TestDelivery(
      parsed.data,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
      environment.APP_BASE_URL,
    );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen een testmail versturen." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "40001" || result.error.code === "23505") {
        return NextResponse.json(
          { error: "Deze testaanvraag of template is intussen gewijzigd." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "Publiceer eerst een geldige template en branding." },
          { status: 422, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De testmail kon niet veilig worden voorbereid." },
        { status: 503, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Alleen beheerders met MFA mogen een testmail versturen." },
        { status: 403, headers: noStore },
      );
    }
    if (error instanceof Error && error.message === "MAIL_V2_TEST_RECIPIENT_UNAVAILABLE") {
      return NextResponse.json(
        { error: "De vaste testinbox is nog niet geconfigureerd." },
        { status: 503, headers: noStore },
      );
    }
    if (error instanceof Error && error.message === "MAIL_V2_TEST_FINALIZE_UNCERTAIN") {
      return NextResponse.json(
        {
          error: "De provideruitkomst kon niet duurzaam worden vastgelegd. Dezelfde aanvraag wordt niet opnieuw verzonden.",
        },
        { status: 503, headers: noStore },
      );
    }
    if (error instanceof Error && error.message.startsWith("MAIL_V2_TEST_")) {
      return NextResponse.json(
        { error: "De testmail is veilig geblokkeerd." },
        { status: 503, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Testmailverzending is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
