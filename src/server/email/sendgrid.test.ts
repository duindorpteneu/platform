import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  sendEmailJob,
  sendParentOtpEmail,
  sendParentOtpV2Email,
} from "@/server/email/sendgrid";
import { renderClaimedEmailJob } from "@/server/email/workspace";

const originalEnv = { ...process.env };
const sender = {
  fromName: "Kledingcommissie Duindorp SV",
  fromEmail: "tenue@duindorpsv.nl",
  replyToEmail: "kledingcommissie@duindorpsv.nl",
};
const deliveryAttemptId = "11111111-1111-4111-8111-111111111112";

beforeEach(() => {
  process.env.EMAIL_ENABLED = "true";
  process.env.SENDGRID_API_KEY = "test-key";
  process.env.SENDGRID_API_BASE_URL = "https://api.sendgrid.com";
  process.env.SENDGRID_FROM_NAME = sender.fromName;
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
    expect(body.from).toEqual({
      email: sender.fromEmail,
      name: sender.fromName,
    });
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

  it("correleert v2-OTP zonder code of ontvanger in provider-metadata", async () => {
    const request = vi.fn().mockResolvedValue(
      new Response(null, {
        status: 202,
        headers: { "x-message-id": "otp-http-message-1" },
      }),
    );
    vi.stubGlobal("fetch", request);
    await expect(sendParentOtpV2Email({
      ...sender,
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Uw verificatiecode",
      text: "Code 123456",
      html: "<p>Code 123456</p>",
    })).resolves.toEqual({
      delivered: true,
      providerMessageId: "otp-http-message-1",
    });
    const body = JSON.parse(request.mock.calls[0][1].body as string);
    expect(body.personalizations[0].custom_args).toEqual({
      delivery_kind: "parent_otp",
      otp_delivery_attempt_id: deliveryAttemptId,
    });
    expect(JSON.stringify(body.personalizations[0].custom_args))
      .not.toMatch(/123456|ouder@example\.nl/u);
    expect(body.tracking_settings).toEqual({
      click_tracking: { enable: false, enable_text: false },
      open_tracking: { enable: false },
      subscription_tracking: { enable: false },
    });
  });

  it("herhaalt een onzekere v2-OTP-aflevering niet automatisch", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response(null, { status: 202 })),
    );
    await expect(sendParentOtpV2Email({
      ...sender,
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Uw verificatiecode",
      text: "Code 123456",
      html: "<p>Code 123456</p>",
    })).resolves.toEqual({
      delivered: false,
      reason: "delivery_uncertain",
      outcome: "delivery_uncertain",
    });
  });

  it("sends a rendered job without PII in custom arguments", async () => {
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 202, headers: { "x-message-id": "sg-message-1" } }));
    vi.stubGlobal("fetch", request);
    const result = await sendEmailJob({
      ...sender,
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Betaling ontvangen",
      text: "Uw betaling is ontvangen.",
      html: "<p>Uw betaling is ontvangen.</p>",
    });
    expect(result).toEqual({ delivered: true, providerMessageId: "sg-message-1" });
    const body = JSON.parse(request.mock.calls[0][1].body as string);
    expect(body.personalizations[0].custom_args).toEqual({
      email_job_id: "11111111-1111-4111-8111-111111111111",
      delivery_attempt_id: deliveryAttemptId,
    });
    expect(JSON.stringify(body.personalizations[0].custom_args)).not.toContain("ouder@example.nl");
    expect(body.tracking_settings).toMatchObject({ click_tracking: { enable: false }, open_tracking: { enable: false } });
    expect(body.from).toEqual({
      email: sender.fromEmail,
      name: sender.fromName,
    });
  });

  it("weigert een job-snapshot die van de omgevingsafzender afwijkt", async () => {
    const request = vi.fn();
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      ...sender,
      fromEmail: "ander@duindorpsv.nl",
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    })).resolves.toEqual({
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("weigert ook een zichtbare afzendernaam die van de omgeving afwijkt", async () => {
    const request = vi.fn();
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      ...sender,
      fromName: "Andere commissie",
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    })).resolves.toEqual({
      delivered: false,
      reason: "configuration_error",
      outcome: "failed",
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("uses the EU API host only when explicitly configured", async () => {
    process.env.SENDGRID_API_BASE_URL = "https://api.eu.sendgrid.com";
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 202, headers: { "x-message-id": "sg-eu-1" } }));
    vi.stubGlobal("fetch", request);
    await sendEmailJob({
      ...sender,
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    });
    expect(request).toHaveBeenCalledWith("https://api.eu.sendgrid.com/v3/mail/send", expect.any(Object));
  });

  it("fails closed when the safety switch is disabled", async () => {
    process.env.EMAIL_ENABLED = "false";
    const request = vi.fn();
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      ...sender,
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    })).resolves.toEqual({ delivered: false, reason: "disabled", outcome: "retry" });
    expect(request).not.toHaveBeenCalled();
  });

  it("marks validation and permanent provider failures as non-retryable", async () => {
    const request = vi.fn().mockResolvedValue(new Response(null, { status: 400 }));
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      ...sender,
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    })).resolves.toEqual({ delivered: false, reason: "provider_rejected", outcome: "failed" });
  });

  it.each([
    ["provider timeoutresponse", vi.fn().mockResolvedValue(new Response(null, { status: 408 }))],
    ["provider 5xx", vi.fn().mockResolvedValue(new Response(null, { status: 503 }))],
    ["202 zonder bericht-ID", vi.fn().mockResolvedValue(new Response(null, { status: 202 }))],
    ["netwerkfout", vi.fn().mockRejectedValue(new TypeError("network failed"))],
  ])("marks %s as delivery-uncertain and never as an automatic retry", async (_label, request) => {
    vi.stubGlobal("fetch", request);
    await expect(sendEmailJob({
      ...sender,
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    })).resolves.toEqual({ delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" });
  });

  it("retries only an explicit provider rejection that is safe to repeat", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 429 })));
    await expect(sendEmailJob({
      ...sender,
      jobId: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: "Onderwerp",
      text: "Bericht",
      html: "<p>Bericht</p>",
    })).resolves.toEqual({ delivered: false, reason: "provider_rejected", outcome: "retry" });
  });

  it("renders the immutable subject and body snapshots from a claimed job", () => {
    const orderId = "11111111-1111-4111-8111-111111111111";
    const rendered = renderClaimedEmailJob({
      id: "22222222-2222-4222-8222-222222222222", deliveryAttemptId, kind: "transactional", recipientEmail: "ouder@example.nl",
      contextKind: "order",
      templateKey: "payment_received", templateVersion: 4, subjectSource: "Snapshot voor {{volledige_naam}}",
      bodySource: "Versie vier: {{bedrag}} is ontvangen.", allowedShortcodes: ["{{volledige_naam}}", "{{bedrag}}"],
      orderId, parentAccountId: null, attempt: 1,
      payload: { orderId, memberId: "33333333-3333-4333-8333-333333333333", firstName: "Sophie", fullName: "Sophie de Bruin", team: "JO11-1", relationNumber: "DSV-1", season: "2026/27", amountCents: 12500, clubName: "Duindorp SV", contactEmail: "kleding@duindorpsv.nl", pickupLocation: "Clubhuis", qrVersion: 1, articles: [], articlesReady: [], articlesBackorder: [] },
    }, "https://tenue.duindorpsv.nl");
    expect(rendered.subject).toBe("Snapshot voor Sophie de Bruin");
    expect(rendered.text).toContain("Versie vier: € 125,00 is ontvangen.");
  });

  it("renders a portal invitation with only a login route and explanation", () => {
    const parentAccountId = "33333333-3333-4333-8333-333333333333";
    const rendered = renderClaimedEmailJob({
      id: "22222222-2222-4222-8222-222222222222",
      deliveryAttemptId,
      kind: "transactional",
      contextKind: "portal_access",
      recipientEmail: "ouder@example.nl",
      templateKey: "portal_access_invite",
      templateVersion: 1,
      subjectSource: "Toegang tot {{clubnaam}}",
      bodySource: "Open {{portaal_url}} en vraag zelf een eenmalige code aan.",
      allowedShortcodes: ["{{clubnaam}}", "{{portaal_url}}"],
      orderId: null,
      parentAccountId,
      payload: {
        parentAccountId,
        clubName: "Duindorp SV",
        contactEmail: "kleding@duindorpsv.nl",
      },
      attempt: 1,
    }, "https://tenue.duindorpsv.nl");
    expect(rendered.text).toContain("https://tenue.duindorpsv.nl/login");
    expect(rendered.text).not.toContain("token=");
    expect(rendered.text).not.toContain("123456");
  });
});
