import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { previewMailTemplateRequestSchema } from "@/lib/mail-v2-contract";
import { previewMailV2Template } from "@/server/email/mail-v2-workspace";
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
    body: BODY_POLICIES.mailTemplate,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.mailTemplate);
  if (!body.ok) return body.response;
  const parsed = previewMailTemplateRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de template-inhoud." },
      { status: 400, headers: noStore },
    );
  }
  try {
    const rendered = await previewMailV2Template(
      parsed.data,
      environment.APP_BASE_URL,
    );
    return NextResponse.json(
      {
        subject: rendered.subject,
        preheader: rendered.preheader,
        html: rendered.html,
        text: rendered.text,
      },
      { headers: noStore },
    );
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Geen toegang tot templatepreview." },
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
      { error: "De preview is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
