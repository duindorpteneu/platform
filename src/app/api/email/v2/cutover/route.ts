import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { manageMailV2CutoverRequestSchema } from "@/lib/mail-v2-contract";
import { changeMailV2Cutover } from "@/server/email/mail-v2-workspace";
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
  const parsed = manageMailV2CutoverRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de cutoverrevisie, reden en actie." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const result = await changeMailV2Cutover(
      parsed.data,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen de mailketen activeren of pauzeren." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De catalogus is intussen gewijzigd. Vernieuw de preflight." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "Cutover geblokkeerd: templates, producenten of branding zijn nog niet volledig bewezen." },
          { status: 422, headers: noStore },
        );
      }
      if (result.error.code === "55000") {
        return NextResponse.json(
          { error: "De mailketen is nog niet geactiveerd en kan daarom niet worden gepauzeerd." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "22023") {
        return NextResponse.json(
          { error: "De opgegeven reden of revisie is ongeldig." },
          { status: 400, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De mailcutover kon niet veilig worden gewijzigd." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(result.data, { headers: noStore });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json(
        { error: "Geen toegang tot de mailcutover." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "De mailcutover is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
