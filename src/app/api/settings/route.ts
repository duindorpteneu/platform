import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { updateSettingsRequestSchema } from "@/lib/settings-audit-contract";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { updateSettings } from "@/server/settings/workspace";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { appBaseUrl: getServerEnv().APP_BASE_URL, body: BODY_POLICIES.jsonMedium });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonMedium);
  if (!body.ok) return body.response;
  const parsed = updateSettingsRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Controleer de instellingen en seizoensbedragen." }, { status: 400 });

  try {
    const result = await updateSettings(parsed.data, normalizeCorrelationId(request.headers.get("x-correlation-id")));
    if (result.error) {
      if (result.error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met MFA mogen instellingen wijzigen." }, { status: 403 });
      if (result.error.code === "22023") return NextResponse.json({ error: "Een instelling voldoet niet aan de toegestane waarden." }, { status: 400 });
      return NextResponse.json({ error: "De instellingen konden niet veilig worden opgeslagen." }, { status: 422 });
    }
    return NextResponse.json({ settings: result.data });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot instellingen." }, { status: 403 });
    if (error instanceof Error && error.message === "SETTINGS_DATABASE_UNAVAILABLE") return NextResponse.json({ error: "Instellingen zijn tijdelijk niet beschikbaar." }, { status: 503 });
    return NextResponse.json({ error: "De instellingen konden niet worden verwerkt." }, { status: 500 });
  }
}
