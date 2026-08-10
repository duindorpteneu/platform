import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { updateStaffRequestSchema } from "@/lib/settings-audit-contract";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { updateStaffProfile } from "@/server/settings/workspace";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { appBaseUrl: getServerEnv().APP_BASE_URL, body: BODY_POLICIES.jsonTiny });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = updateStaffRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Controleer naam, rol en status." }, { status: 400 });

  try {
    const result = await updateStaffProfile(parsed.data, normalizeCorrelationId(request.headers.get("x-correlation-id")));
    if (result.error) {
      if (result.error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met MFA mogen medewerkers wijzigen." }, { status: 403 });
      if (result.error.code === "P0002") return NextResponse.json({ error: "Het medewerkersprofiel bestaat niet meer." }, { status: 404 });
      if (result.error.code === "23514") return NextResponse.json({ error: "Deze wijziging zou beheerderstoegang blokkeren en is daarom geweigerd." }, { status: 409 });
      if (result.error.code === "22023") return NextResponse.json({ error: "Controleer naam, rol en status." }, { status: 400 });
      return NextResponse.json({ error: "Het medewerkersprofiel kon niet veilig worden opgeslagen." }, { status: 422 });
    }
    return NextResponse.json({ staff: result.data });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot medewerkersbeheer." }, { status: 403 });
    return NextResponse.json({ error: "Het medewerkersprofiel kon niet worden verwerkt." }, { status: 500 });
  }
}
