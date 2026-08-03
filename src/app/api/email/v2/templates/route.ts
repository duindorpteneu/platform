import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { manageMailTemplateRequestSchema } from "@/lib/mail-v2-contract";
import {
  publishMailV2Template,
  saveMailV2TemplateDraft,
} from "@/server/email/mail-v2-workspace";
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
    body: BODY_POLICIES.mailTemplate,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.mailTemplate);
  if (!body.ok) return body.response;
  const parsed = manageMailTemplateRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de template-inhoud en revisie." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const correlationId = normalizeCorrelationId(request.headers.get("x-correlation-id"));
    const result = parsed.data.action === "save"
      ? await saveMailV2TemplateDraft(parsed.data, correlationId)
      : await publishMailV2Template(parsed.data, correlationId);
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen templates beheren." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De template is intussen gewijzigd. Vernieuw de pagina." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "De template-revisie bestaat niet meer." },
          { status: 404, headers: noStore },
        );
      }
      if (result.error.code === "22023" || result.error.code === "23514") {
        return NextResponse.json(
          { error: "De template voldoet niet aan het shortcode- en beschermde-blokkencontract." },
          { status: 422, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De template kon niet veilig worden opgeslagen." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Geen toegang tot templatebeheer." },
        { status: 403, headers: noStore },
      );
    }
    if (error instanceof Error && error.message.startsWith("MAIL_V2_")) {
      return NextResponse.json(
        { error: "De template bevat ongeldige of onveilige inhoud." },
        { status: 400, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Templatebeheer is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
