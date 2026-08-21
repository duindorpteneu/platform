import { describe, expect, it } from "vitest";
import type {
  PreparedParentOtpV2,
  PreparedParentOtpV3,
} from "@/lib/mail-v2-contract";
import {
  authorizeParentOtpV2,
  completeParentOtpV2,
  getParentOtpEmailTemplate,
  prepareParentOtpV2,
  prepareParentOtpV3,
  renderParentOtpEmail,
  renderParentOtpV2,
  renderParentOtpV3,
} from "@/server/email/otp";

const template = {
  templateKey: "verification_code" as const,
  templateVersion: 3,
  subjectSource: "Uw code voor {{clubnaam}}",
  bodySource: "Code: {{verificatiecode}}. Vragen? {{contact_email}}",
  allowedShortcodes: ["{{verificatiecode}}", "{{clubnaam}}", "{{contact_email}}"],
  clubName: "Duindorp SV",
  contactEmail: "kleding@duindorpsv.nl",
};

const preparation: PreparedParentOtpV2 = {
  status: "prepared",
  deliveryAttemptId: "11111111-1111-4111-8111-111111111111",
  expiresInMinutes: 10,
  template: {
    id: "22222222-2222-4222-8222-222222222222",
    templateKey: "login_otp",
    subjectSource: "Uw code voor {{club_name}}",
    preheaderSource:
      "Gebruik deze code binnen {{otp_expiry_minutes}} minuten.",
    bodyTipTap: {
      type: "doc" as const,
      content: [
        {
          type: "paragraph" as const,
          content: [{
            type: "text" as const,
            text: "Gebruik uw eenmalige verificatiecode.",
          }],
        },
        {
          type: "protectedBlock" as const,
          attrs: { kind: "otp_code" as const },
        },
        {
          type: "protectedBlock" as const,
          attrs: { kind: "otp_validity" as const },
        },
        {
          type: "protectedBlock" as const,
          attrs: { kind: "otp_warning" as const },
        },
      ],
    },
    contentHash: "a".repeat(64),
    allowedShortcodes: [
      "club_name",
      "recipient_name",
      "contact_email",
      "otp_expiry_minutes",
      "privacy_url",
    ],
    allowedProtectedNodes: [
      "otp_code",
      "otp_validity",
      "otp_warning",
    ],
    requiredProtectedNodes: [
      "otp_code",
      "otp_validity",
      "otp_warning",
    ],
  },
  branding: {
    id: "33333333-3333-4333-8333-333333333333",
    clubName: "Duindorp SV",
    logoAssetPath: "/duindorp-sv-logo.png",
    fromName: "Kledingcommissie Duindorp SV",
    fromEmail: "kleding@duindorpsv.nl",
    replyToEmail: "kleding@duindorpsv.nl",
    contactEmail: "kleding@duindorpsv.nl",
    clubAddressLine: "Houtrustlaan 1",
    clubPostalCode: "2566 ZW",
    clubCity: "Den Haag",
    pickupName: "Free-Kick Sport",
    pickupAddressLine: "De Savornin Lohmanplein 45",
    pickupPostalCode: "2566 AE",
    pickupCity: "Den Haag",
    privacyUrl: "https://duindorpsv.nl/privacy",
    primaryColor: "#0055A4",
    secondaryColor: "#003B73",
    accentColor: "#F2C94C",
    footerText: "Kledingcommissie Duindorp SV",
    contrastValidated: true,
    contentHash: "b".repeat(64),
  },
};

const preparationV3: PreparedParentOtpV3 = {
  status: "prepared",
  deliveryAttemptId: preparation.deliveryAttemptId,
  challengeId: "44444444-4444-4444-8444-444444444444",
  expiresAt: "2026-08-21T00:55:00.000Z",
  cooldownUntil: "2026-08-21T00:46:30.000Z",
  reused: true,
  expiresInMinutes: 9,
  template: {
    ...preparation.template,
    bodyTipTap: {
      type: "doc",
      content: [
        { type: "protectedBlock", attrs: { kind: "otp_code" } },
        { type: "protectedBlock", attrs: { kind: "otp_validity" } },
        { type: "protectedBlock", attrs: { kind: "otp_direct_login" } },
        { type: "protectedBlock", attrs: { kind: "otp_warning" } },
      ],
    },
    allowedProtectedNodes: [
      "otp_code",
      "otp_validity",
      "otp_direct_login",
      "otp_warning",
    ],
    requiredProtectedNodes: [
      "otp_code",
      "otp_validity",
      "otp_direct_login",
      "otp_warning",
    ],
  },
  branding: preparation.branding,
};

describe("ouder-OTP e-mailtemplate", () => {
  it("reads and strictly validates the active database template", async () => {
    const client = { rpc: async () => ({ data: template, error: null }) };
    await expect(getParentOtpEmailTemplate(client)).resolves.toEqual(template);
  });

  it("renders the real code only in the transient message", () => {
    const rendered = renderParentOtpEmail(template, "654321");
    expect(rendered.subject).toBe("Uw code voor Duindorp SV");
    expect(rendered.text).toBe("Code: 654321. Vragen? kleding@duindorpsv.nl");
    expect(rendered.html).toContain("654321");
  });

  it("rejects invalid codes and malformed database responses", async () => {
    expect(() => renderParentOtpEmail(template, "12345")).toThrow("PARENT_OTP_CODE_INVALID");
    const client = { rpc: async () => ({ data: { ...template, extra: "leak" }, error: null }) };
    await expect(getParentOtpEmailTemplate(client)).rejects.toThrow("PARENT_OTP_EMAIL_TEMPLATE_INVALID");
  });

  it("bindt voorbereiding en completion strikt aan de v2-RPCs", async () => {
    const calls: Array<[string, Record<string, unknown>]> = [];
    const client = {
      rpc: async (name: string, parameters: Record<string, unknown>) => {
        calls.push([name, parameters]);
        if (name === "prepare_parent_otp_delivery_v1") {
          return { data: preparation, error: null };
        }
        if (name === "authorize_parent_otp_delivery_v1") {
          return { data: true, error: null };
        }
        return {
          data: {
            status: "completed",
            outcome: "accepted",
            reused: false,
          },
          error: null,
        };
      },
    };
    await expect(prepareParentOtpV2(
      client,
      "ouder@example.nl",
      "c".repeat(64),
      "2026-08-03T12:10:00.000Z",
    )).resolves.toEqual(preparation);
    await expect(authorizeParentOtpV2(
      client,
      preparation.deliveryAttemptId,
    )).resolves.toBe(true);
    await expect(completeParentOtpV2(
      client,
      preparation.deliveryAttemptId,
      {
        outcome: "accepted",
        providerMessageId: "provider-http-id",
      },
    )).resolves.toMatchObject({
      status: "completed",
      outcome: "accepted",
    });
    expect(calls).toContainEqual([
      "complete_parent_otp_delivery_v1",
      {
        p_delivery_attempt_id: preparation.deliveryAttemptId,
        p_outcome: "accepted",
        p_provider_http_message_id: "provider-http-id",
        p_error_code: null,
      },
    ]);
  });

  it("bindt challenge-v3 voorbereiding aan de voorgestelde UUID en hash", async () => {
    const rpc = async (name: string, parameters: Record<string, unknown>) => {
      expect(name).toBe("prepare_parent_otp_delivery_v3");
      expect(parameters).toEqual({
        p_email: "ouder@example.nl",
        p_challenge_id: preparationV3.challengeId,
        p_code_hash: "c".repeat(64),
        p_force_new: false,
        p_actor_user_id: null,
      });
      return { data: preparationV3, error: null };
    };
    await expect(prepareParentOtpV3(
      { rpc },
      "ouder@example.nl",
      preparationV3.challengeId,
      "c".repeat(64),
    )).resolves.toEqual(preparationV3);
  });

  it("legt providerbewijs via de v2-completion vast zonder ontvangerdata", async () => {
    const calls: Array<[string, Record<string, unknown>]> = [];
    const client = {
      rpc: async (name: string, parameters: Record<string, unknown>) => {
        calls.push([name, parameters]);
        return {
          data: {
            status: "completed",
            outcome: "provider_rejected",
            reused: false,
          },
          error: null,
        };
      },
    };

    await completeParentOtpV2(
      client,
      preparation.deliveryAttemptId,
      {
        outcome: "provider_rejected",
        errorCode: "provider_rejected",
      },
      {
        provider: "smtp",
        providerState: "permanent_rejection",
        responseCode: "550",
        enhancedStatusCode: "5.1.1",
        recipientFailure: true,
      },
    );

    expect(calls).toEqual([[
      "complete_parent_otp_delivery_v2",
      {
        p_delivery_attempt_id: preparation.deliveryAttemptId,
        p_outcome: "provider_rejected",
        p_provider_http_message_id: null,
        p_error_code: "provider_rejected",
        p_provider: "smtp",
        p_provider_state: "permanent_rejection",
        p_response_code: "550",
        p_enhanced_status_code: "5.1.1",
        p_recipient_failure: true,
      },
    ]]);
    expect(JSON.stringify(calls)).not.toContain("ouder@example.nl");
  });

  it("rendert de code alleen in het vluchtige beschermde blok", () => {
    const rendered = renderParentOtpV2(
      preparation,
      "654321",
      "https://tenue.example",
    );
    expect(rendered.subject).toBe("Uw code voor Duindorp SV");
    expect(rendered.text).toContain("654321");
    expect(rendered.html).toContain("654321");
    expect(rendered.text).toContain("10 minuten");
    expect(rendered.fromEmail).toBe("kleding@duindorpsv.nl");
    expect(JSON.stringify(preparation)).not.toContain("654321");
  });

  it("rendert v3 met dezelfde code, vaste deadline en fragmentlink", () => {
    const credential = `v1.${preparationV3.challengeId}.${"A".repeat(43)}`;
    const rendered = renderParentOtpV3(
      preparationV3,
      "654321",
      credential,
      "https://tenue.example",
    );
    expect(rendered.text).toContain("654321");
    expect(rendered.text).toContain("Direct inloggen");
    expect(rendered.text).toContain("dezelfde code opnieuw");
    expect(rendered.html).toContain(
      `https://tenue.example/login/direct#${credential}`,
    );
    expect(rendered.html).toContain("Geldig tot:");
    expect(JSON.stringify(preparationV3)).not.toContain("654321");
    expect(JSON.stringify(preparationV3)).not.toContain(credential);
  });
});
