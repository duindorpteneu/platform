import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sendEmailJob, sendParentOtpEmail } from "@/server/email/sendgrid";
import { renderClaimedEmailJob } from "@/server/email/workspace";

const originalEnv = { ...process.env };

beforeEach(() => {
  process.env.EMAIL_ENABLED = "true";
  process.env.SENDGRID_API_KEY = "test-key";
  process.env.SENDGRID_API_BASE_URL = "https://api.sendgrid.com";
  process.env.SENDGRID_FROM_EMAIL = "tenue@duindorpsv.nl";
  process.env.SENDGRID_REPLY_TO_EMAIL = "kledingcommissie@duindorpsv.nl";
});

afterEach(() => {
  process.env = { ...originalEnv };
  vi.unstubAllGlobals();
});

describe("SendGrid delivery boundary", () => {
  it("keeps OTP direct and disables tracking", async () => {
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 202 }));
    vi.stubGlobal("fetch", request);
    await expect(sendParentOtpEmail("ouder@example.nl", {
      subject: "Uw verificatiecode",
      text: "Uw verificatiecode is 123456.",
      html: "<p>Uw verificatiecode is <strong>123456</strong>.</p>",
    })).resolves.toEqual({ delivered: true });
    const body = JSON.parse(request.mock.calls[0][1].body as string);
    expect(body.dynamic_template_data).toBeUndefined();
    expect(body.template_id).toBeUndefined();
    expect(body.subject).toBe("Uw verificatiecode");
    expect(body.content).toEqual([
      { type: "text/plain", value: "Uw verificatiecode is 123456." },
      { type: "text/html", value: "<p>Uw verificatiecode is <strong>123456</strong>.</p>" },
    ]);
    expect(body.reply_to).toEqual({ email: "kledingcommissie@duindorpsv.nl" });
    expect(body.tracking_settings.open_tracking.enable).toBe(false);
  });

  it("fails closed when OTP reply-to is not configured", async () => {
    delete process.env.SENDGRID_REPLY_TO_EMAIL;
    const request = vi.fn();
    vi.stubGlobal("fetch", request);
    await expect(sendParentOtpEmail("ouder@example.nl", {
      subject: "Uw verificatiecode", text: "Code 123456", html: "<p>Code 123456</p>",
    })).resolves.toEqual({ delivered: false, reason: "configuration_error" });
    expect(request).not.toHaveBeenCalled();
  });

  it("sends a rendered job without PII in custom arguments", async () => {
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 202, headers: { "x-message-id": "sg-message-1" } }));
    vi.stubGlobal("fetch", request);
    const result = await sendEmailJob({
      jobId: "11111111-1111-4111-8111-111111111111",
      recipientEmail: "ouder@example.nl",
      subject: "Betaling ontvangen",
      text: "Uw betaling is ontvangen.",
      html: "<p>Uw betaling is ontvangen.</p>",
      replyToEmail: "kledingcommissie@duindorpsv.nl",
    });
    expect(result).toEqual({ delivered: true, providerMessageId: "sg-message-1" });
    const body = JSON.parse(request.mock.calls[0][1].body as string);
    expect(body.personalizations[0].custom_args).toEqual({ email_job_id: "11111111-1111-4111-8111-111111111111" });
    expect(JSON.stringify(body.personalizations[0].custom_args)).not.toContain("ouder@example.nl");
    expect(body.tracking_settings).toMatchObject({ click_tracking: { enable: false }, open_tracking: { enable: false } });
  });

  it("uses the EU API host only when explicitly configured", async () => {
    process.env.SENDGRID_API_BASE_URL = "https://api.eu.sendgrid.com";
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 202, headers: { "x-message-id": "sg-eu-1" } }));
    vi.stubGlobal("fetch", request);
    await sendEmailJob({
      jobId: "11111111-1111-4111-8111-111111111111",
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
      replyToEmail: "kledingcommissie@duindorpsv.nl",
    });
    expect(request).toHaveBeenCalledWith("https://api.eu.sendgrid.com/v3/mail/send", expect.any(Object));
  });

  it("fails closed when the safety switch is disabled", async () => {
    process.env.EMAIL_ENABLED = "false";
    const request = vi.fn();
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      jobId: "11111111-1111-4111-8111-111111111111",
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
      replyToEmail: "kledingcommissie@duindorpsv.nl",
    })).resolves.toEqual({ delivered: false, reason: "disabled", retryable: true });
    expect(request).not.toHaveBeenCalled();
  });

  it("marks validation and permanent provider failures as non-retryable", async () => {
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 400 }));
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      jobId: "11111111-1111-4111-8111-111111111111",
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
      replyToEmail: "kledingcommissie@duindorpsv.nl",
    })).resolves.toEqual({ delivered: false, reason: "provider_error", retryable: false });
  });

  it("renders the immutable subject and body snapshots from a claimed job", () => {
    const orderId = "11111111-1111-4111-8111-111111111111";
    const rendered = renderClaimedEmailJob({
      id: "22222222-2222-4222-8222-222222222222", kind: "transactional", recipientEmail: "ouder@example.nl",
      templateKey: "payment_received", templateVersion: 4, subjectSource: "Snapshot voor {{volledige_naam}}",
      bodySource: "Versie vier: {{bedrag}} is ontvangen.", allowedShortcodes: ["{{volledige_naam}}", "{{bedrag}}"],
      orderId, attempt: 1,
      payload: { orderId, memberId: "33333333-3333-4333-8333-333333333333", firstName: "Sophie", fullName: "Sophie de Bruin", team: "JO11-1", relationNumber: "DSV-1", season: "2026/27", amountCents: 12500, clubName: "Duindorp SV", contactEmail: "kleding@duindorpsv.nl", pickupLocation: "Clubhuis", qrVersion: 1, articles: [], articlesReady: [], articlesBackorder: [] },
    }, "https://tenue.duindorpsv.nl");
    expect(rendered.subject).toBe("Snapshot voor Sophie de Bruin");
    expect(rendered.text).toContain("Versie vier: € 125,00 is ontvangen.");
  });
});
