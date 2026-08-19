import { NextResponse } from "next/server";
import { z } from "zod";
import { confirmSnsSubscription, parseSesOperationalEvent, parseSnsEnvelope, verifySnsEnvelope } from "@/server/email/providers/ses-webhook";
import { BODY_POLICIES, readBodyRequest } from "@/server/security/route-guard";
import { validateBodyHeaders } from "@/server/security/request";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
export const runtime = "nodejs"; export const dynamic = "force-dynamic";
const responseSchema = z.object({ recorded:z.number().int().nonnegative(), ignored:z.number().int().nonnegative(), quarantined:z.number().int().nonnegative(), pending:z.literal(true).optional() }).strict();
const readinessSchema = z.object({ ready:z.number().int().nonnegative() }).strict();
function deferredWebhookResponse(){ return NextResponse.json({error:"Webhookverwerking wordt opnieuw geprobeerd."},{status:503,headers:{"Cache-Control":"no-store","Retry-After":"30"}}); }
function logWebhookRejection(code:string,status:number){ operationalLogger.warn("ses.webhook_rejected",{code,provider:"ses",route:"/api/webhooks/ses",status}); }
export async function POST(request:Request){
 const headers=validateBodyHeaders(request,BODY_POLICIES.sendgridWebhook); if(!headers.ok) return NextResponse.json({error:"Ongeldige webhookpayload."},{status:headers.status});
 const body=await readBodyRequest(request,BODY_POLICIES.sendgridWebhook); if(!body.ok) return body.response;
 let raw:string; try{raw=new TextDecoder("utf-8",{fatal:true}).decode(body.data);}catch{return NextResponse.json({error:"Ongeldige webhookpayload."},{status:400});}
 let envelope; try{envelope=parseSnsEnvelope(raw);}catch{logWebhookRejection("payload_invalid",400);return NextResponse.json({error:"Ongeldige webhookpayload."},{status:400});}
 if(!await verifySnsEnvelope(envelope)){logWebhookRejection("signature_invalid",401);return NextResponse.json({error:"Ongeldige webhookauthenticiteit."},{status:401});}
 if(envelope.Type==="SubscriptionConfirmation"){ const confirmed=await confirmSnsSubscription(envelope); return NextResponse.json({confirmed},{status:confirmed?200:503}); }
 let event; try{event=parseSesOperationalEvent(envelope);}catch{logWebhookRejection("event_invalid",400);return NextResponse.json({error:"Ongeldige webhookpayload."},{status:400});}
 if(!event)return NextResponse.json({recorded:0,ignored:1,quarantined:0},{status:202}); const events=[event];
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
    return deferredWebhookResponse();
  }
  if (readinessError) {
    logWebhookRejection("readiness_invalid", 422);
    return NextResponse.json(
      { error: "Webhook kon niet veilig worden verwerkt." },
      { status: 422, headers: { "Cache-Control": "no-store" } },
    );
  }
  const readiness = readinessSchema.safeParse(readinessData);
  if (readiness.success && readiness.data.ready < events.length) {
    return deferredWebhookResponse();
  }
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
    if (parsed.data.pending) return deferredWebhookResponse();
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
