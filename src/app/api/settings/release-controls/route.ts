import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { manageReleaseControlRequestSchema } from "@/lib/release-control-contract";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { changeReleaseControl } from "@/server/settings/release-controls";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "no-store" };

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    appBaseUrl: getServerEnv().APP_BASE_URL,
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = manageReleaseControlRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer procespoort, revisie en reden." },
      { status: 400, headers },
    );
  }
  try {
    const result = await changeReleaseControl(
      parsed.data,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen procespoorten wijzigen." },
          { status: 403, headers },
        );
      }
      if (result.error.code === "40001") {
        return NextResponse.json(
          { error: "De preflight is verouderd. Vernieuw de pagina." },
          { status: 409, headers },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "Activatie is geblokkeerd door open reconciliatiepunten." },
          { status: 422, headers },
        );
      }
      if (result.error.code === "22023") {
        return NextResponse.json(
          { error: "Deze procespoort of reden is ongeldig." },
          { status: 400, headers },
        );
      }
      return NextResponse.json(
        { error: "De procespoort kon niet veilig worden gewijzigd." },
        { status: 422, headers },
      );
    }
    return NextResponse.json(
      { controls: result.data },
      { headers },
    );
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot procespoorten." },
        { status: 403, headers },
      );
    }
    return NextResponse.json(
      { error: "Procespoorten zijn tijdelijk niet beschikbaar." },
      { status: 503, headers },
    );
  }
}
