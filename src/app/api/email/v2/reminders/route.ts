import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { manageMailReminderRequestSchema } from "@/lib/mail-v2-contract";
import {
  saveMailReminderRule,
  setMailReminderRuleActive,
} from "@/server/email/mail-v2-reminders";
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
    body: BODY_POLICIES.jsonSmall,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = manageMailReminderRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer het herinneringsschema en de stille uren." },
      { status: 400, headers: noStore },
    );
  }

  try {
    const correlationId = normalizeCorrelationId(
      request.headers.get("x-correlation-id"),
    );
    const result = parsed.data.action === "save"
      ? await saveMailReminderRule(parsed.data, correlationId)
      : await setMailReminderRuleActive(parsed.data, correlationId);
    if (result.error) {
      if (result.error.code === "42501") {
        return NextResponse.json(
          { error: "Alleen beheerders met MFA mogen herinneringen beheren." },
          { status: 403, headers: noStore },
        );
      }
      if (result.error.code === "P0002") {
        return NextResponse.json(
          { error: "De herinneringsregel bestaat niet meer." },
          { status: 404, headers: noStore },
        );
      }
      if (["40001", "23505"].includes(result.error.code)) {
        return NextResponse.json(
          { error: "De regel is intussen gewijzigd. Vernieuw de pagina." },
          { status: 409, headers: noStore },
        );
      }
      if (result.error.code === "23514") {
        return NextResponse.json(
          { error: "De regel kan pas actief worden met een open seizoen en gepubliceerde template." },
          { status: 422, headers: noStore },
        );
      }
      if (result.error.code === "22023") {
        return NextResponse.json(
          { error: "De herinneringsinstellingen zijn ongeldig." },
          { status: 400, headers: noStore },
        );
      }
      return NextResponse.json(
        { error: "De herinneringsregel kon niet veilig worden opgeslagen." },
        { status: 422, headers: noStore },
      );
    }
    return NextResponse.json(
      result.data,
      {
        status: parsed.data.action === "save" && parsed.data.ruleId === null
          ? 201
          : 200,
        headers: noStore,
      },
    );
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot herinneringsbeheer." },
        { status: 403, headers: noStore },
      );
    }
    return NextResponse.json(
      { error: "Herinneringsbeheer is tijdelijk niet beschikbaar." },
      { status: 503, headers: noStore },
    );
  }
}
