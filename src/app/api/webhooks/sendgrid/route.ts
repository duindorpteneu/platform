import { NextResponse } from "next/server";
import { z } from "zod";
import { isFreshSendGridTimestamp, parseSendGridOperationalEvents, verifySendGridSignature } from "@/server/email/webhook";
import { BODY_POLICIES, readBodyRequest } from "@/server/security/route-guard";
import { validateBodyHeaders } from "@/server/security/request";
import { handleEdgeBodyProbe } from "@/server/security/edge-body-probe";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const responseSchema = z.object({
  recorded: z.number().int().nonnegative(),
  ignored: z.number().int().nonnegative(),
  quarantined: z.number().int().nonnegative(),
}).strict();
const readinessSchema = z.object({
  ready: z.number().int().nonnegative(),
}).strict();

function logWebhookRejection(code: string, status: number) {
  operationalLogger.warn("sendgrid.webhook_rejected", {
    code,
    provider: "sendgrid",
    route: "/api/webhooks/sendgrid",
    status,
  });
}

export async function POST(request: Request) {
  const edgeProbe = await handleEdgeBodyProbe(request, "sendgrid-webhook");
  if (edgeProbe) return edgeProbe;
  const publicKey = process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY;
  if (!publicKey) return NextResponse.json({ error: "Webhook niet geconfigureerd." }, { status: 503 });
  const headers = validateBodyHeaders(request, BODY_POLICIES.sendgridWebhook);
  if (!headers.ok) {
    logWebhookRejection(
      headers.status === 413
        ? "body_too_large"
        : "content_type_invalid",
      headers.status,
    );
    return NextResponse.json(
      { error: headers.status === 413 ? "Webhookpayload te groot." : "Ongeldig inhoudstype." },
      { status: headers.status },
    );
  }
  const body = await readBodyRequest(request, BODY_POLICIES.sendgridWebhook);
  if (!body.ok) {
    logWebhookRejection("body_read_failed", body.response.status);
    return body.response;
  }
  const signature = request.headers.get("x-twilio-email-event-webhook-signature");
  const timestamp = request.headers.get("x-twilio-email-event-webhook-timestamp");
  if (!isFreshSendGridTimestamp(timestamp) || !verifySendGridSignature(body.data, timestamp, signature, publicKey)) {
    logWebhookRejection("signature_invalid", 401);
    return NextResponse.json({ error: "Ongeldige webhookauthenticiteit." }, { status: 401 });
  }

  let rawBody: string;
  try { rawBody = new TextDecoder("utf-8", { fatal: true }).decode(body.data); }
  catch {
    logWebhookRejection("utf8_invalid", 400);
    return NextResponse.json(
      { error: "Ongeldige webhookpayload." },
      { status: 400, headers: { "Cache-Control": "no-store" } },
    );
  }
  let events;
  try { events = parseSendGridOperationalEvents(rawBody); }
  catch {
    logWebhookRejection("payload_invalid", 400);
    return NextResponse.json(
      { error: "Ongeldige webhookpayload." },
      { status: 400 },
    );
  }
  if (events.length === 0) {
    return NextResponse.json(
      { recorded: 0, ignored: 0, quarantined: 0 },
      { status: 202 },
    );
  }

  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Webhookverwerking tijdelijk niet beschikbaar." }, { status: 503 });
  const readinessEvents = events.map((event) => ({
    target: event.target,
    email_job_id:
      event.target === "email_job" ? event.emailJobId : null,
    delivery_attempt_id:
      event.target === "mail_test" ? null : event.deliveryAttemptId,
    delivery_id:
      event.target === "mail_test" ? event.testDeliveryId : null,
  }));
  const { data: readinessData, error: readinessError } =
    await admin.schema("app").rpc(
      "assert_sendgrid_events_ready_v1",
      { p_events: readinessEvents },
    );
  if (readinessError?.code === "40001") {
    operationalLogger.warn("sendgrid.webhook_deferred", {
      code: "acceptance_pending",
      provider: "sendgrid",
      route: "/api/webhooks/sendgrid",
      status: 503,
    });
    return NextResponse.json(
      { error: "Webhookverwerking wordt opnieuw geprobeerd." },
      {
        status: 503,
        headers: {
          "Cache-Control": "no-store",
          "Retry-After": "30",
        },
      },
    );
  }
  if (readinessError) {
    logWebhookRejection("readiness_invalid", 422);
    return NextResponse.json(
      { error: "Webhook kon niet veilig worden verwerkt." },
      { status: 422, headers: { "Cache-Control": "no-store" } },
    );
  }
  const readiness = readinessSchema.safeParse(readinessData);
  if (!readiness.success || readiness.data.ready !== events.length) {
    return NextResponse.json(
      { error: "Ongeldig antwoord van de database." },
      { status: 502, headers: { "Cache-Control": "no-store" } },
    );
  }
  const queuedEvents = events.filter(
    (event) => event.target === "email_job",
  );
  const otpEvents = events.filter(
    (event) => event.target === "parent_otp",
  );
  const testEvents = events.filter(
    (event) => event.target === "mail_test",
  );
  const results: z.infer<typeof responseSchema>[] = [];
  if (queuedEvents.length > 0) {
    const { data, error } = await admin.schema("app").rpc(
      "record_sendgrid_events_v4",
      {
        p_events: queuedEvents.map((event) => ({
          email_job_id: event.emailJobId,
          delivery_attempt_id: event.deliveryAttemptId,
          event_id: event.providerEventId,
          provider_message_id: event.providerMessageId,
          event_type: event.eventType,
          occurred_at: event.occurredAt,
        })),
      },
    );
    if (error) return NextResponse.json({ error: "Webhook kon niet veilig worden verwerkt." }, { status: 422 });
    const parsed = responseSchema.safeParse(data);
    if (!parsed.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    results.push(parsed.data);
  }
  if (otpEvents.length > 0) {
    const { data, error } = await admin.schema("app").rpc(
      "record_parent_otp_sendgrid_events_v3",
      {
        p_events: otpEvents.map((event) => ({
          delivery_attempt_id: event.deliveryAttemptId,
          event_id: event.providerEventId,
          provider_message_id: event.providerMessageId,
          event_type: event.eventType,
          occurred_at: event.occurredAt,
        })),
      },
    );
    if (error) return NextResponse.json({ error: "Webhook kon niet veilig worden verwerkt." }, { status: 422 });
    const parsed = responseSchema.safeParse(data);
    if (!parsed.success) return NextResponse.json({ error: "Ongeldig antwoord van de database." }, { status: 502 });
    results.push(parsed.data);
  }
  if (testEvents.length > 0) {
    const { data, error } = await admin.schema("app").rpc(
      "record_mail_test_sendgrid_events_v4",
      {
        p_events: testEvents.map((event) => ({
          delivery_id: event.testDeliveryId,
          event_id: event.providerEventId,
          provider_message_id: event.providerMessageId,
          event_type: event.eventType,
          occurred_at: event.occurredAt,
        })),
      },
    );
    if (error) {
      return NextResponse.json(
        { error: "Webhook kon niet veilig worden verwerkt." },
        { status: 422 },
      );
    }
    const parsed = responseSchema.safeParse(data);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Ongeldig antwoord van de database." },
        { status: 502 },
      );
    }
    results.push(parsed.data);
  }
  const aggregate = results.reduce(
    (total, result) => ({
      recorded: total.recorded + result.recorded,
      ignored: total.ignored + result.ignored,
      quarantined: total.quarantined + result.quarantined,
    }),
    { recorded: 0, ignored: 0, quarantined: 0 },
  );
  return NextResponse.json(aggregate, { status: 202 });
}
