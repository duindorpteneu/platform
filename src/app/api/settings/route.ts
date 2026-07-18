import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { updateSettingsRequestSchema } from "@/lib/settings-audit-contract";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { guardBrowserMutation } from "@/server/security/route-guard";
import { updateSettings } from "@/server/settings/workspace";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { appBaseUrl: getServerEnv().APP_BASE_URL, body: { allowedContentTypes: ["application/json"], maxBytes: 20_000 } });
  if (guarded) return guarded;
  let body: unknown;
  try { body = await request.json(); } catch { return NextResponse.json({ error: "Ongeldige JSON-aanvraag." }, { status: 400 }); }
  const parsed = updateSettingsRequestSchema.safeParse(body);
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

