import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { retryMailV2ProjectionRequestSchema } from "@/lib/mail-v2-contract";
import { retryMailV2Projection } from "@/server/email/mail-v2-workspace";
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
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = retryMailV2ProjectionRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de projectie, poging en herstelreden." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const result = await retryMailV2Projection(
      parsed.data,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen een projectie herstellen." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "De mailprojectie bestaat niet meer." },
          { status: 404, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De projectie is intussen gewijzigd. Vernieuw de preflight." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "55000") {
        return NextResponse.json(
          { error: "Deze projectie is niet veilig herstelbaar of nog niet verzendbaar." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "22023") {
        return NextResponse.json(
          { error: "De herstelreden of poging is ongeldig." },
          { status: 400, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De mailprojectie kon niet veilig worden hersteld." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot projectieherstel." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Projectieherstel is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
