import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import {
  portalAccessPreflightRequestSchema,
  portalAccessPreviewResponseSchema,
} from "@/lib/portal-access-contract";
import { portalAccessExceptionResponse, portalAccessRpcErrorResponse } from "@/server/portal-access/http";
import { previewPortalAccess } from "@/server/portal-access/workspace";
import {
  fictionalEmailPreviewValues,
  renderEmailTemplate,
  validateTemplateForPurpose,
} from "@/server/email/templates";
import { createPortalAccessPreviewToken } from "@/server/security/portal-access-preview-token";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  const parsed = portalAccessPreflightRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Selecteer één tot vijfhonderd unieke leden." }, { status: 400 });
  }
  try {
    const result = await previewPortalAccess(parsed.data);
    if (result.error) return portalAccessRpcErrorResponse(result.error);
    const pepper = getServerEnv().PARENT_TOKEN_PEPPER;
    if (!pepper) throw new Error("PORTAL_ACCESS_PREVIEW_PEPPER_MISSING");
    const ids = parsed.data.operation === "activate"
      ? parsed.data.memberSeasonIds
      : parsed.data.grantIds;
    const { revision, mailTemplate, ...visible } = result.data;
    if (parsed.data.operation === "activate" && !mailTemplate) {
      throw new Error("PORTAL_ACCESS_INVITE_TEMPLATE_MISSING");
    }
    let mailPreview = null;
    if (mailTemplate) {
      const allowed = mailTemplate.allowedShortcodes.map(
        (shortcode) => shortcode.slice(2, -2),
      );
      validateTemplateForPurpose(
        mailTemplate.key,
        mailTemplate.subjectSource,
        mailTemplate.bodySource,
        allowed,
      );
      const values = fictionalEmailPreviewValues();
      const rendered = renderEmailTemplate(
        mailTemplate.subjectSource,
        mailTemplate.bodySource,
        allowed,
        {
          ...values,
          clubnaam: mailTemplate.clubName,
          contact_email: mailTemplate.contactEmail ?? "",
          portaal_url: new URL("/login", getServerEnv().APP_BASE_URL).toString(),
        },
      );
      mailPreview = {
        subject: rendered.subject,
        text: rendered.text,
        templateVersion: mailTemplate.version,
      };
    }
    const response = portalAccessPreviewResponseSchema.parse({
      ...visible,
      mailPreview,
      previewToken: createPortalAccessPreviewToken({
        operation: parsed.data.operation,
        actorId: result.staff.userId,
        seasonId: parsed.data.seasonId,
        ids,
        revision,
      }, pepper),
    });
    return NextResponse.json(response, {
      headers: { "Cache-Control": "no-store, private" },
    });
  } catch (error) {
    return portalAccessExceptionResponse(error);
  }
}
