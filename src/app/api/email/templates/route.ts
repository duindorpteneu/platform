import { NextResponse } from "next/server";
import { updateEmailTemplateRequestSchema, updateEmailTemplateResponseSchema } from "@/lib/email-contract";
import { updateEmailTemplate } from "@/server/email/workspace";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonMedium }); if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonMedium);
  if (!body.ok) return body.response;
  const parsed = updateEmailTemplateRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Controleer onderwerp, inhoud en templateversie." }, { status: 400 });
  try {
    const { data, error } = await updateEmailTemplate(parsed.data);
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot e-mailtemplates." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "De template bestaat niet meer." }, { status: 404 });
      if (error.code === "40001") return NextResponse.json({ error: "De template is intussen gewijzigd. Vernieuw de pagina." }, { status: 409 });
      return NextResponse.json({ error: "De template kon niet veilig worden opgeslagen." }, { status: 422 });
    }
    const response = updateEmailTemplateResponseSchema.safeParse(data);
    if (!response.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    return NextResponse.json(response.data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot e-mailtemplates." }, { status: 403 });
    if (error instanceof Error && error.message === "EMAIL_TEMPLATE_NOT_FOUND") return NextResponse.json({ error: "De template bestaat niet meer." }, { status: 404 });
    if (error instanceof Error && error.message === "EMAIL_VERIFICATION_CODE_REQUIRED") return NextResponse.json({ error: "De verificatiecode-template moet {{verificatiecode}} bevatten." }, { status: 400 });
    if (error instanceof Error && ["EMAIL_SUBJECT_INVALID", "EMAIL_BODY_INVALID", "EMAIL_SHORTCODE_NOT_ALLOWED", "EMAIL_TEMPLATE_SYNTAX_INVALID"].includes(error.message)) return NextResponse.json({ error: "De template bevat niet-toegestane inhoud of shortcodes." }, { status: 400 });
    if (error instanceof Error && error.message === "EMAIL_DATABASE_UNAVAILABLE") return NextResponse.json({ error: "Templatebeheer is tijdelijk niet beschikbaar." }, { status: 503 });
    return NextResponse.json({ error: "De template kon niet worden verwerkt." }, { status: 500 });
  }
}
