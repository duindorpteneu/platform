import { afterEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ ses: vi.fn(), sg: vi.fn() }));
vi.mock("./providers/ses", () => ({ sendEmailJob: mocks.ses, sendParentOtpV2Email: mocks.ses, sendMailV2TestEmail: mocks.ses, sesRuntimeHealth: () => ({ runtimeValueValid:true,runtimeEnabled:true,provider:"ses",providerConfigured:true,credentialsValid:true,keyFingerprintMatches:true }) }));
vi.mock("./providers/sendgrid", () => ({ sendEmailJob: mocks.sg, sendParentOtpV2Email: mocks.sg, sendMailV2TestEmail: mocks.sg, sendGridRuntimeHealth: () => ({ runtimeValueValid:true,runtimeEnabled:true,providerConfigured:true,keyFingerprintMatches:true }) }));
import { sendEmailJob } from "./provider";
const input = { jobId:"11111111-1111-4111-8111-111111111111",deliveryAttemptId:"11111111-1111-4111-8111-111111111112",recipientEmail:"ouder@example.nl",subject:"Test",text:"Test",html:"<p>Test</p>",fromName:"Duindorp SV",fromEmail:"mail@example.nl",replyToEmail:"reply@example.nl" };
afterEach(()=>{ delete process.env.EMAIL_PROVIDER; vi.clearAllMocks(); });
describe("email provider selector",()=>{
 it("selecteert SES expliciet",async()=>{process.env.EMAIL_PROVIDER="ses";mocks.ses.mockResolvedValue({delivered:true,providerMessageId:"ses-1"});await expect(sendEmailJob(input)).resolves.toMatchObject({providerMessageId:"ses-1"});expect(mocks.sg).not.toHaveBeenCalled();});
 it("behoudt SendGrid als expliciete fallback",async()=>{process.env.EMAIL_PROVIDER="sendgrid";mocks.sg.mockResolvedValue({delivered:true,providerMessageId:"sg-1"});await expect(sendEmailJob(input)).resolves.toMatchObject({providerMessageId:"sg-1"});});
 it("valt zonder selector fail-closed",async()=>{await expect(sendEmailJob(input)).resolves.toMatchObject({delivered:false,reason:"configuration_error"});expect(mocks.ses).not.toHaveBeenCalled();expect(mocks.sg).not.toHaveBeenCalled();});
});
