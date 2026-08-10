import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { manageMailBrandingRequestSchema } from "@/lib/mail-v2-contract";
import {
  publishMailV2Branding,
  saveMailV2BrandingDraft,
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
    body: BODY_POLICIES.jsonMedium,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonMedium);
  if (!body.ok) return body.response;
  const parsed = manageMailBrandingRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de branding- en contactvelden." },
      { status: 400, headers: noStore },
    );
  }
  try {
    const correlationId = normalizeCorrelationId(request.headers.get("x-correlation-id"));
    const result = parsed.data.action === "save"
      ? await saveMailV2BrandingDraft(parsed.data, correlationId)
      : await publishMailV2Branding(parsed.data, correlationId);
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen branding beheren." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De branding is intussen gewijzigd. Vernieuw de pagina." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "Publicatie is geblokkeerd; controleer kleurcontrast en vaste clubidentiteit." },
          { status: 422, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De branding kon niet veilig worden opgeslagen." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Geen toegang tot brandingbeheer." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Brandingbeheer is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
