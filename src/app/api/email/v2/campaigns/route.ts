import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { mailV2CampaignRequestSchema } from "@/lib/mail-v2-contract";
import {
  confirmMailV2Campaign,
  previewMailV2Campaign,
} from "@/server/email/mail-v2-campaigns";
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
    body: BODY_POLICIES.emailBulk,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.emailBulk);
  if (!body.ok) return body.response;
  const parsed = mailV2CampaignRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer berichttype, unieke selectie en aanvraag-ID." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const result = parsed.data.action === "preview"
      ? await previewMailV2Campaign(parsed.data)
      : await confirmMailV2Campaign(
        parsed.data,
        normalizeCorrelationId(request.headers.get("x-correlation-id")),
      );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Geen MFA-bevoegdheid voor deze campagne." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "De campagnepreflight bestaat niet meer." },
          { status: 404, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De doelgroep is gewijzigd. Maak een nieuwe preflight." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23505") {
        return NextResponse.json(
          { error: "De aanvraag-ID hoort bij een andere campagne." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "De selectie of actuele toestand blokkeert deze campagne." },
          { status: 422, headers: noStore },
        );
      }
      if (result.error.code === "54000") {
        return NextResponse.json(
          { error: "Een oudergroep bevat meer dan 100 events; splits de selectie." },
          { status: 422, headers: noStore },
        );
      }
      if (result.error.code === "55000") {
        return NextResponse.json(
          { error: "Mail-v2 is nog niet actief of de preflight is verlopen." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "22023") {
        return NextResponse.json(
          { error: "Dit berichttype of deze selectie is niet toegestaan." },
          { status: 400, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De campagne kon niet veilig worden voorbereid." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(
      result.data,
      {
        status: parsed.data.action === "confirm" && !result.data.reused
          ? 201
          : 200,
        headers: noStore,
      },
    );
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot campagnes." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Campagnes zijn tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
