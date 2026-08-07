import { NextResponse } from "next/server";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import { deliveryNotificationConfirmRequestSchema } from "@/lib/delivery-notification-contract";
import {
  confirmDeliveryNotificationProposal,
  getDeliveryNotificationProposal,
} from "@/server/stock/delivery-notifications";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const paramsSchema = z.object({ draftId: z.string().uuid() }).strict();
const noStore = { "Cache-Control": "no-store" };

export async function GET(
  _request: Request,
  context: { params: Promise<{ draftId: string }> },
) {
  const params = paramsSchema.safeParse(await context.params);
  if (!params.success) {
    return NextResponse.json(
      { error: "Ongeldig leveringvoorstel." },
      { status: 400, headers: noStore },
    );
  }
  try {
    const result = await getDeliveryNotificationProposal(params.data.draftId);
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "AAL2 en voorraadbevoegdheid zijn vereist." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "Voor deze levering bestaat geen notificatievoorstel." },
          { status: 404, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "Het notificatievoorstel kon niet worden geladen." },
        { status: 503, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot leveringnotificaties." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Leveringnotificaties zijn tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}

export async function POST(
  request: Request,
  context: { params: Promise<{ draftId: string }> },
) {
  const guarded = guardBrowserMutation(request, {
    appBaseUrl: getServerEnv().APP_BASE_URL,
    body: BODY_POLICIES.jsonStandard,
  });
  if (guarded) return guarded;
  const params = paramsSchema.safeParse(await context.params);
  const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  const parsed = deliveryNotificationConfirmRequestSchema.safeParse(body.data);
  if (!params.success || !parsed.success) {
    return NextResponse.json(
      { error: "Controleer de unieke selectie en aanvraag-ID." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const proposal = await getDeliveryNotificationProposal(
      params.data.draftId,
    );
    if (
      proposal.error
      || !proposal.data
      || proposal.data.id !== parsed.data.proposalId
    ) {
      return NextResponse.json(
        { error: "Het notificatievoorstel hoort niet bij deze levering." },
        {
          status: proposal.error?.code === "42501" ? 403 : 404,
          headers: noStore,
        },
      );
    }
    const result = await confirmDeliveryNotificationProposal(
      parsed.data,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "AAL2 en voorraadbevoegdheid zijn vereist." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "Het notificatievoorstel bestaat niet meer." },
          { status: 404, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De actuele geschiktheid is gewijzigd; vernieuw eerst." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23505") {
        return NextResponse.json(
          { error: "De aanvraag-ID hoort bij een andere selectie." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "Een geselecteerde regel hoort niet bij dit voorstel." },
          { status: 422, headers: noStore },
        );
      }
      if (result.error.code === "55000") {
        return NextResponse.json(
          { error: "Dit notificatievoorstel is al definitief bevestigd." },
          { status: 409, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "Het notificatievoorstel kon niet veilig worden bevestigd." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(
      result.data,
      {
        status: result.data?.reused ? 200 : 201,
        headers: noStore,
      },
    );
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot leveringnotificaties." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Leveringnotificaties zijn tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
