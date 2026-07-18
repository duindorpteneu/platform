import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { inviteStaffRequestSchema } from "@/lib/settings-audit-contract";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { guardBrowserMutation } from "@/server/security/route-guard";
import { inviteStaff } from "@/server/settings/invitations";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { appBaseUrl: getServerEnv().APP_BASE_URL, body: { allowedContentTypes: ["application/json"], maxBytes: 4_000 } });
  if (guarded) return guarded;
  let body: unknown;
  try { body = await request.json(); } catch { return NextResponse.json({ error: "Ongeldige JSON-aanvraag." }, { status: 400 }); }
  const parsed = inviteStaffRequestSchema.safeParse(body);
  if (!parsed.success) return NextResponse.json({ error: "Controleer e-mailadres, naam en rol." }, { status: 400 });

  try {
    const staff = await inviteStaff(parsed.data, normalizeCorrelationId(request.headers.get("x-correlation-id")));
    return NextResponse.json({ staff }, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot medewerkersbeheer." }, { status: 403 });
    if (error instanceof Error && error.message === "STAFF_INVITE_NOT_CONFIGURED") return NextResponse.json({ error: "Uitnodigen is in deze omgeving nog niet geconfigureerd." }, { status: 503 });
    if (error instanceof Error && error.message === "STAFF_INVITE_PROVIDER_FAILED") return NextResponse.json({ error: "De uitnodiging kon niet worden verstuurd. Mogelijk bestaat dit account al." }, { status: 409 });
    if (error instanceof Error && error.message === "STAFF_INVITE_REGISTRATION_FAILED") return NextResponse.json({ error: "De uitnodiging is teruggedraaid omdat het profiel niet kon worden vastgelegd." }, { status: 422 });
    return NextResponse.json({ error: "De medewerker kon niet veilig worden uitgenodigd." }, { status: 500 });
  }
}
