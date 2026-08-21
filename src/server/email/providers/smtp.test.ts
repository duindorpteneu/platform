import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ sendMail: vi.fn(), verify: vi.fn() }));
vi.mock("nodemailer", () => ({ default: { createTransport: vi.fn(() => mocks) } }));

import { classifySmtpError, sendSmtpEmail, smtpRuntimeHealth } from "@/server/email/providers/smtp";

const message = {
  recipientEmail: "ouder@example.nl", subject: "Onderwerp", text: "Tekst", html: "<p>Tekst</p>",
  fromName: "Kledingcommissie Duindorp SV", fromEmail: "kleding@duindorpsv.nl", replyToEmail: "kleding@duindorpsv.nl",
};

beforeEach(() => {
  vi.clearAllMocks();
  Object.assign(process.env, {
    EMAIL_ENABLED: "true", SMTP_HOST: "mail.voetbalassist.nl", SMTP_PORT: "587", SMTP_SECURE: "false",
    SMTP_USERNAME: "kleding@duindorpsv.nl", SMTP_PASSWORD: "not-a-real-secret",
    SMTP_FROM_NAME: message.fromName, SMTP_FROM_EMAIL: message.fromEmail, SMTP_REPLY_TO_EMAIL: message.replyToEmail,
  });
});

describe("VoetbalAssist SMTP-adapter", () => {
  it("accepteert een geldige 587/STARTTLS-configuratie", () => {
    expect(smtpRuntimeHealth()).toEqual({ provider: "smtp", providerConfigured: true });
  });

  it("faalt gesloten als configuratie ontbreekt", async () => {
    delete process.env.SMTP_PASSWORD;
    await expect(sendSmtpEmail(message)).resolves.toMatchObject({ delivered: false, reason: "configuration_error", outcome: "failed" });
  });

  it.each([421, 450, 451, 452])("maakt SMTP %i retrybaar", (responseCode) => {
    expect(classifySmtpError(Object.assign(new Error("safe"), { responseCode }))).toMatchObject({ delivered: false, outcome: "retry", deliveryState: "temporary_failure", providerCode: String(responseCode) });
  });

  it("maakt auth failure definitief", () => {
    expect(classifySmtpError(Object.assign(new Error("safe"), { responseCode: 535, code: "EAUTH" }))).toMatchObject({ reason: "configuration_error", outcome: "failed" });
  });

  it("onderdrukt alleen een bewezen permanent onjuist ontvangstadres", () => {
    expect(classifySmtpError(Object.assign(new Error("safe"), {
      responseCode: 550,
      response: "550 5.1.1 Mailbox bestaat niet",
    }))).toMatchObject({
      reason: "provider_rejected",
      outcome: "failed",
      deliveryState: "permanent_rejection",
      providerCode: "550",
      enhancedStatusCode: "5.1.1",
      recipientFailure: true,
    });
  });

  it.each([
    [550, "550 5.2.2 Mailbox full"],
    [550, "550 5.7.1 Rejected by policy"],
    [554, "554 5.6.0 Message content rejected"],
    [550, "550 Requested action not taken"],
  ])("behandelt SMTP %i zonder adresbewijs niet als recipient failure", (responseCode, response) => {
    expect(classifySmtpError(Object.assign(new Error("safe"), {
      responseCode,
      response,
    }))).toMatchObject({
      reason: "provider_rejected",
      outcome: "failed",
      deliveryState: "permanent_rejection",
      providerCode: String(responseCode),
      recipientFailure: false,
    });
  });

  it("herkent een enhanced recipientstatus in een multiline SMTP-response", () => {
    expect(classifySmtpError(Object.assign(new Error("safe"), {
      responseCode: 551,
      response: "551-5.1.1 Bad destination mailbox address\n551 5.1.1 User unknown",
    }))).toMatchObject({
      enhancedStatusCode: "5.1.1",
      recipientFailure: true,
    });
  });

  it("onderscheidt pre-DATA timeout van onzekere DATA-disconnect", () => {
    expect(classifySmtpError(Object.assign(new Error("safe"), { code: "ETIMEDOUT", command: "CONN" }))).toMatchObject({ reason: "provider_rejected", outcome: "retry", deliveryState: "temporary_failure" });
    expect(classifySmtpError(Object.assign(new Error("safe"), { code: "ECONNRESET", command: "EHLO" }))).toMatchObject({ reason: "provider_rejected", outcome: "retry", deliveryState: "temporary_failure" });
    expect(classifySmtpError(Object.assign(new Error("safe"), { code: "ECONNRESET", command: "DATA" }))).toMatchObject({ reason: "delivery_uncertain", outcome: "delivery_uncertain", deliveryState: "delivery_uncertain" });
  });

  it("noemt SMTP-acceptatie expliciet geen aflevering", async () => {
    mocks.sendMail.mockResolvedValueOnce({
      messageId: "smtp-message-1",
      accepted: ["accepted"],
      response: "250 2.0.0 Message accepted",
    });
    await expect(sendSmtpEmail(message)).resolves.toEqual({
      delivered: true,
      deliveryState: "provider_accepted",
      providerMessageId: "smtp-message-1",
      providerCode: "250",
      enhancedStatusCode: "2.0.0",
    });
  });
});
