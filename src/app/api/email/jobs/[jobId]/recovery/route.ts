import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { recoverEmailJobRequestSchema } from "@/lib/email-contract";
import { recoverEmailJob } from "@/server/email/recovery";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request, { params }: { params: Promise<{ jobId: string }> }) {
  const guarded = guardBrowserMutation(request, {
    appBaseUrl: getServerEnv().APP_BASE_URL,
    body: BODY_POLICIES.jsonSmall,
  });
  if (guarded) return guarded;

  const { jobId } = await params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(jobId)) {
    return NextResponse.json({ error: "Ongeldige e-mailjob." }, { status: 400 });
  }
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = recoverEmailJobRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Controleer het herstelbesluit en het providerbewijs." }, { status: 400 });
  }

  try {
    const result = await recoverEmailJob(jobId, parsed.data, normalizeCorrelationId(request.headers.get("x-correlation-id")));
    if (result.error) {
      if (result.error.code === "42501") return NextResponse.json({ error: "Alleen beheerders met MFA mogen e-mailjobs herstellen." }, { status: 403 });
      if (result.error.code === "P0002") return NextResponse.json({ error: "De e-mailjob bestaat niet meer." }, { status: 404 });
      if (result.error.code === "40001") return NextResponse.json({ error: "De e-mailjob is intussen gewijzigd. Vernieuw de pagina." }, { status: 409 });
      if (result.error.code === "23505") return NextResponse.json({ error: "Dit providerbericht is al aan een andere job gekoppeld." }, { status: 409 });
      if (result.error.code === "23514") return NextResponse.json({ error: "Deze e-mailjob kan niet veilig met dit besluit worden hersteld." }, { status: 409 });
      if (result.error.code === "22023") return NextResponse.json({ error: "Het providerbewijs voldoet niet aan de herstelvoorwaarden." }, { status: 400 });
      return NextResponse.json({ error: "De e-mailjob kon niet veilig worden hersteld." }, { status: 422 });
    }
    return NextResponse.json(result.data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Alleen beheerders met MFA mogen e-mailjobs herstellen." }, { status: 403 });
    }
    if (error instanceof Error && error.message === "EMAIL_DATABASE_UNAVAILABLE") {
      return NextResponse.json({ error: "E-mailherstel is tijdelijk niet beschikbaar." }, { status: 503 });
    }
    return NextResponse.json({ error: "De e-mailjob kon niet worden verwerkt." }, { status: 500 });
  }
}
