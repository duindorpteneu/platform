import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { createSeasonRequestSchema } from "@/lib/settings-audit-contract";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { createSeason } from "@/server/settings/workspace";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { appBaseUrl: getServerEnv().APP_BASE_URL, body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = createSeasonRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Controleer naam, datums en standaardbedrag." }, { status: 400 });
  try {
    const result = await createSeason(parsed.data, normalizeCorrelationId(request.headers.get("x-correlation-id")));
    if (result.error) {
      if (result.error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met MFA mogen een seizoen toevoegen." }, { status: 403 });
      if (result.error.code === "23505") return NextResponse.json({ error: "Er bestaat al een seizoen met deze naam." }, { status: 409 });
      if (result.error.code === "22023") return NextResponse.json({ error: "Controleer naam, datums en standaardbedrag." }, { status: 400 });
      return NextResponse.json({ error: "Het seizoen kon niet veilig worden toegevoegd." }, { status: 422 });
    }
    return NextResponse.json({ settings: result.data }, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot seizoensbeheer." }, { status: 403 });
    if (error instanceof Error && error.message === "SETTINGS_DATABASE_UNAVAILABLE") return NextResponse.json({ error: "Instellingen zijn tijdelijk niet beschikbaar." }, { status: 503 });
    return NextResponse.json({ error: "Het seizoen kon niet worden verwerkt." }, { status: 500 });
  }
}
