import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ smtp: vi.fn(), sendgrid: vi.fn() }));
vi.mock("@/server/email/providers/smtp", () => ({ sendSmtpEmail: mocks.smtp, smtpRuntimeHealth: () => ({ providerConfigured: true }) }));
vi.mock("@/server/email/sendgrid", () => ({ sendEmailJob: mocks.sendgrid, sendMailV2TestEmail: mocks.sendgrid, sendParentOtpV2Email: mocks.sendgrid, sendParentOtpEmail: mocks.sendgrid, sendGridRuntimeHealth: () => ({ providerConfigured: true, keyFingerprintMatches: true }) }));
import { sendEmailJob } from "@/server/email/provider";

const message = { jobId: crypto.randomUUID(), deliveryAttemptId: crypto.randomUUID(), recipientEmail: "x@example.nl", subject: "s", text: "t", html: "h", fromName: "Name", fromEmail: "from@example.nl", replyToEmail: "reply@example.nl" };

describe("e-mailproviderselectie", () => {
  beforeEach(() => { vi.clearAllMocks(); delete process.env.EMAIL_PROVIDER; });
  it("faalt gesloten zonder provider", async () => expect(sendEmailJob(message)).resolves.toMatchObject({ reason: "configuration_error" }));
  it("gebruikt geen SendGrid wanneer SMTP geselecteerd is", async () => {
    process.env.EMAIL_PROVIDER = "smtp";
    mocks.smtp.mockResolvedValue({ delivered: true, providerMessageId: "smtp-1" });
    await expect(sendEmailJob(message)).resolves.toMatchObject({ delivered: true });
    expect(mocks.sendgrid).not.toHaveBeenCalled();
  });
});
