import { NextResponse } from "next/server";
import { z } from "zod";
import { isFreshSendGridTimestamp, parseSendGridOperationalEvents, verifySendGridSignature } from "@/server/email/webhook";
import { BODY_POLICIES, readBodyRequest } from "@/server/security/route-guard";
import { validateBodyHeaders } from "@/server/security/request";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const responseSchema = z.object({
  recorded: z.number().int().nonnegative(),
  ignored: z.number().int().nonnegative(),
  quarantined: z.number().int().nonnegative(),
}).strict();

export async function POST(request: Request) {
  const publicKey = process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY;
  if (!publicKey) return NextResponse.json({ error: "Webhook niet geconfigureerd." }, { status: 503 });
  const headers = validateBodyHeaders(request, BODY_POLICIES.sendgridWebhook);
  if (!headers.ok) {
    return NextResponse.json(
      { error: headers.status === 413 ? "Webhookpayload te groot." : "Ongeldig inhoudstype." },
      { status: headers.status },
    );
  }
  const body = await readBodyRequest(request, BODY_POLICIES.sendgridWebhook);
  if (!body.ok) return body.response;
  const signature = request.headers.get("x-twilio-email-event-webhook-signature");
  const timestamp = request.headers.get("x-twilio-email-event-webhook-timestamp");
  if (!isFreshSendGridTimestamp(timestamp) || !verifySendGridSignature(body.data, timestamp, signature, publicKey)) {
    return NextResponse.json({ error: "Ongeldige webhookauthenticiteit." }, { status: 401 });
  }

  let rawBody: string;
  try { rawBody = new TextDecoder("utf-8", { fatal: true }).decode(body.data); }
  catch {
    return NextResponse.json(
      { error: "Ongeldige webhookpayload." },
      { status: 400, headers: { "Cache-Control": "no-store" } },
    );
  }
  let events;
  try { events = parseSendGridOperationalEvents(rawBody); }
  catch { return NextResponse.json({ error: "Ongeldige webhookpayload." }, { status: 400 }); }
  if (events.length === 0) {
    return NextResponse.json(
      { recorded: 0, ignored: 0, quarantined: 0 },
      { status: 202 },
    );
  }

  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Webhookverwerking tijdelijk niet beschikbaar." }, { status: 503 });
  const { data, error } = await admin.schema("app").rpc("record_sendgrid_events_v2", {
    p_events: events.map((event) => ({
      email_job_id: event.emailJobId,
      delivery_attempt_id: event.deliveryAttemptId,
      event_id: event.providerEventId,
      provider_message_id: event.providerMessageId,
      event_type: event.eventType,
      occurred_at: event.occurredAt,
    })),
  });
  if (error) return NextResponse.json({ error: "Webhook kon niet veilig worden verwerkt." }, { status: 422 });
  const parsed = responseSchema.safeParse(data);
  if (!parsed.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
  return NextResponse.json(parsed.data, { status: 202 });
}
