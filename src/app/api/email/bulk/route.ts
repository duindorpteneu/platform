import { NextResponse } from "next/server";
import { emailBulkRequestSchema } from "@/lib/email-contract";
import { createEmailPreviewToken, verifyEmailPreviewToken } from "@/server/email/preview-token";
import { assertEligibleBulkSelection, createEmailBulk, getEmailWorkspace, renderFictionalTemplatePreview } from "@/server/email/workspace";
import { guardBrowserMutation } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request); if (guarded) return guarded;
  let body: unknown;
  try { body = await request.json(); } catch { return NextResponse.json({ error: "Ongeldige JSON-aanvraag." }, { status: 400 }); }
  const parsed = emailBulkRequestSchema.safeParse(body);
  if (!parsed.success) return NextResponse.json({ error: "Controleer template en unieke bestellingen." }, { status: 400 });
  const pepper = process.env.PARENT_TOKEN_PEPPER;
  if (!pepper) return NextResponse.json({ error: "Beveiligde bevestiging is niet geconfigureerd." }, { status: 503 });

  try {
    if (parsed.data.action === "preview") {
      const { workspace } = await getEmailWorkspace();
      const orders = assertEligibleBulkSelection(workspace, parsed.data.templateKey, parsed.data.orderIds);
      const preview = renderFictionalTemplatePreview(workspace, parsed.data.templateKey);
      const previewToken = createEmailPreviewToken(parsed.data.templateKey, orders.map((order) => order.orderId), pepper);
      return NextResponse.json({
        recipientCount: orders.length,
        previewToken,
        preview: { subject: preview.subject, text: preview.text },
        expiresInSeconds: 600,
      });
    }

    const token = verifyEmailPreviewToken(parsed.data.previewToken, pepper);
    const { data, error } = await createEmailBulk(token.templateKey, token.orderIds, token.batchKey);
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot bulkmail." }, { status: 403 });
      if (error.code === "23514") return NextResponse.json({ error: "De selectie is gewijzigd en niet meer volledig geschikt." }, { status: 409 });
      if (error.code === "23505") return NextResponse.json({ error: "De bevestigingssleutel hoort bij een andere selectie." }, { status: 409 });
      return NextResponse.json({ error: "De e-mailjobs konden niet veilig worden aangemaakt." }, { status: 422 });
    }
    return NextResponse.json(data, { status: data.reused ? 200 : 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot bulkmail." }, { status: 403 });
    if (error instanceof Error && error.message === "EMAIL_PREVIEW_TOKEN_EXPIRED") return NextResponse.json({ error: "De voorvertoning is verlopen. Controleer de selectie opnieuw." }, { status: 409 });
    if (error instanceof Error && ["EMAIL_BULK_SELECTION_NOT_VISIBLE", "EMAIL_BULK_SELECTION_NOT_ELIGIBLE"].includes(error.message)) return NextResponse.json({ error: "De selectie is gewijzigd en niet meer volledig geschikt." }, { status: 409 });
    if (error instanceof Error && error.message.startsWith("EMAIL_PREVIEW_TOKEN")) return NextResponse.json({ error: "Ongeldige bevestiging." }, { status: 400 });
    return NextResponse.json({ error: "De bulkactie kon niet worden verwerkt." }, { status: 500 });
  }
}
