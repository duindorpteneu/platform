import { describe, expect, it } from "vitest";
import { parseSesOperationalEvent, validateSigningCertUrl, type SnsEnvelope } from "./ses-webhook";
const id="11111111-1111-4111-8111-111111111111", attempt="11111111-1111-4111-8111-111111111112";
function envelope(eventType:string):SnsEnvelope{return {Type:"Notification",MessageId:`sns-${eventType}`,TopicArn:"arn:aws:sns:eu-west-1:123456789012:ses",Message:JSON.stringify({eventType,mail:{messageId:"ses-message",timestamp:"2026-08-19T00:00:00.000Z",tags:{delivery_kind:["email_job"],email_job_id:[id],delivery_attempt_id:[attempt]}}}),Timestamp:"2026-08-19T00:00:00.000Z",SignatureVersion:"2",Signature:"x",SigningCertURL:"https://sns.eu-west-1.amazonaws.com/SimpleNotificationService-test.pem"};}
describe("SES lifecycle normalization",()=>{
 it.each([["DELIVERY","delivered"],["BOUNCE","bounced"],["COMPLAINT","dropped"],["REJECT","dropped"],["DELIVERY_DELAY","deferred"]])("mapt %s",(source,target)=>expect(parseSesOperationalEvent(envelope(source))?.eventType).toBe(target));
 it("markeert SEND niet als afgeleverd",()=>expect(parseSesOperationalEvent(envelope("SEND"))).toBeNull());
 it("weigert een SSRF-certificaat-URL",()=>expect(()=>validateSigningCertUrl("https://sns.eu-west-1.amazonaws.com.evil.test/SimpleNotificationService-x.pem")).toThrow());
});
