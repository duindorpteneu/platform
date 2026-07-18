import { NextResponse } from "next/server";
import { previewEmailTemplateRequestSchema } from "@/lib/email-contract";
import { fictionalEmailPreviewValues, renderEmailTemplate } from "@/server/email/templates";
import { getEmailWorkspace, templateShortcodeNames } from "@/server/email/workspace";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const origin = request.headers.get("origin");
  if (!origin || origin !== new URL(request.url).origin) return NextResponse.json({ error: "Ongeldige aanvraagbron." }, { status: 403 });
  const parsed = previewEmailTemplateRequestSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Controleer onderwerp en inhoud." }, { status: 400 });
  try {
    const { workspace } = await getEmailWorkspace();
    const template = workspace.templates.find((candidate) => candidate.id === parsed.data.templateId);
    if (!template) return NextResponse.json({ error: "De template bestaat niet meer." }, { status: 404 });
    const rendered = renderEmailTemplate(
      parsed.data.subjectSource,
      parsed.data.bodySource,
      templateShortcodeNames(template),
      fictionalEmailPreviewValues(),
    );
    return NextResponse.json({ subject: rendered.subject, text: rendered.text });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot e-mailtemplates." }, { status: 403 });
    if (error instanceof Error && error.message.startsWith("EMAIL_")) return NextResponse.json({ error: "De template bevat niet-toegestane inhoud of shortcodes." }, { status: 400 });
    return NextResponse.json({ error: "De voorvertoning kon niet worden gemaakt." }, { status: 500 });
  }
}
