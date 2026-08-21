import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ smtp: vi.fn(), sendgrid: vi.fn() }));
vi.mock("@/server/email/providers/smtp", () => ({ sendSmtpEmail: mocks.smtp, smtpRuntimeHealth: () => ({ providerConfigured: true }) }));
vi.mock("@/server/email/sendgrid", () => ({ sendEmailJob: mocks.sendgrid, sendMailV2TestEmail: mocks.sendgrid, sendParentOtpV2Email: mocks.sendgrid, sendParentOtpEmail: mocks.sendgrid, sendGridRuntimeHealth: () => ({ providerConfigured: true, keyFingerprintMatches: true }) }));
import { emailProviderCapabilities, sendEmailJob, sendMailV2TestEmail } from "@/server/email/provider";

const message = { jobId: crypto.randomUUID(), deliveryAttemptId: crypto.randomUUID(), recipientEmail: "x@example.nl", subject: "s", text: "t", html: "h", fromName: "Name", fromEmail: "from@example.nl", replyToEmail: "reply@example.nl" };

describe("e-mailproviderselectie", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.EMAIL_PROVIDER;
    delete process.env.EMAIL_SMOKE_RECIPIENT;
    delete process.env.SENDGRID_SMOKE_RECIPIENT;
  });
  it("faalt gesloten zonder provider", async () => expect(sendEmailJob(message)).resolves.toMatchObject({ reason: "configuration_error" }));
  it("gebruikt geen SendGrid wanneer SMTP geselecteerd is", async () => {
    process.env.EMAIL_PROVIDER = "smtp";
    mocks.smtp.mockResolvedValue({ delivered: true, providerMessageId: "smtp-1" });
    await expect(sendEmailJob(message)).resolves.toMatchObject({ delivered: true });
    expect(mocks.sendgrid).not.toHaveBeenCalled();
  });
  it("rapporteert SMTP zonder late afleverfeedback en zonder credentials", () => {
    Object.assign(process.env, {
      EMAIL_PROVIDER: "smtp",
      EMAIL_ENABLED: "true",
      SMTP_FROM_NAME: "Kledingcommissie Duindorp SV",
      SMTP_USERNAME: "secret-user@example.nl",
      SMTP_PASSWORD: "secret-password",
    });
    const capabilities = emailProviderCapabilities();
    expect(capabilities).toEqual({
      provider: "smtp",
      providerName: "VoetbalAssist SMTP",
      runtimeEnabled: true,
      providerConfigured: true,
      senderName: "Kledingcommissie Duindorp SV",
      feedbackCapability: "smtp_sync_only",
    });
    expect(JSON.stringify(capabilities)).not.toContain("secret-user");
    expect(JSON.stringify(capabilities)).not.toContain("secret-password");
  });
  it("hergebruikt de bestaande smoke inbox bij tijdelijke SMTP-staging", async () => {
    process.env.EMAIL_PROVIDER = "smtp";
    process.env.SENDGRID_SMOKE_RECIPIENT = "smoke@example.invalid";
    mocks.smtp.mockResolvedValue({ delivered: true, providerMessageId: "smtp-smoke" });
    await expect(sendMailV2TestEmail({
      testDeliveryId: crypto.randomUUID(),
      subject: "Smoke",
      text: "Smoke",
      html: "<p>Smoke</p>",
      fromName: message.fromName,
      fromEmail: message.fromEmail,
      replyToEmail: message.replyToEmail,
    })).resolves.toMatchObject({ delivered: true });
    expect(mocks.smtp).toHaveBeenCalledWith(expect.objectContaining({
      recipientEmail: "smoke@example.invalid",
    }));
    expect(mocks.sendgrid).not.toHaveBeenCalled();
  });
});
