import { parentOtpEmailTemplateSchema, type ParentOtpEmailTemplate } from "@/lib/email-contract";
import {
  parentOtpV2CompletionSchema,
  parentOtpV2PreparationSchema,
  type PreparedParentOtpV2,
} from "@/lib/mail-v2-contract";
import { renderMailV2 } from "@/server/email/mail-v2";
import { renderEmailTemplate } from "@/server/email/templates";

type OtpTemplateClient = {
  rpc(name: "get_parent_otp_email_template"): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

export async function getParentOtpEmailTemplate(client: OtpTemplateClient) {
  const { data, error } = await client.rpc("get_parent_otp_email_template");
  if (error) throw new Error("PARENT_OTP_EMAIL_TEMPLATE_UNAVAILABLE");
  const parsed = parentOtpEmailTemplateSchema.safeParse(data);
  if (!parsed.success) throw new Error("PARENT_OTP_EMAIL_TEMPLATE_INVALID");
  return parsed.data;
}

export function renderParentOtpEmail(template: ParentOtpEmailTemplate, code: string) {
  if (!/^\d{6}$/.test(code)) throw new Error("PARENT_OTP_CODE_INVALID");
  return renderEmailTemplate(
    template.subjectSource,
    template.bodySource,
    template.allowedShortcodes.map((shortcode) => shortcode.slice(2, -2)),
    {
      voornaam: "",
      volledige_naam: "",
      team: "",
      relatienummer: "",
      seizoen: "",
      bedrag: "",
      betaallink: "",
      qr_code: "",
      artikelen_af_te_halen: "",
      artikelen_nalevering: "",
      afhaallocatie: "",
      clubnaam: template.clubName,
      contact_email: template.contactEmail ?? "",
      verificatiecode: code,
      portaal_url: "",
    },
  );
}

type OtpV2Client = {
  rpc(
    name:
      | "prepare_parent_otp_delivery_v1"
      | "authorize_parent_otp_delivery_v1"
      | "complete_parent_otp_delivery_v1",
    parameters: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

export async function prepareParentOtpV2(
  client: OtpV2Client,
  email: string,
  codeHash: string,
  expiresAt: string,
) {
  const { data, error } = await client.rpc(
    "prepare_parent_otp_delivery_v1",
    {
      p_email: email,
      p_code_hash: codeHash,
      p_expires_at: expiresAt,
    },
  );
  if (error) throw new Error("PARENT_OTP_V2_PREPARATION_FAILED");
  const parsed = parentOtpV2PreparationSchema.safeParse(data);
  if (!parsed.success) throw new Error("PARENT_OTP_V2_PREPARATION_INVALID");
  return parsed.data;
}

export async function authorizeParentOtpV2(
  client: OtpV2Client,
  deliveryAttemptId: string,
) {
  const { data, error } = await client.rpc(
    "authorize_parent_otp_delivery_v1",
    { p_delivery_attempt_id: deliveryAttemptId },
  );
  return !error && data === true;
}

export type ParentOtpV2Outcome =
  | {
      outcome: "accepted";
      providerMessageId: string;
      errorCode?: never;
    }
  | {
      outcome:
        | "provider_rejected"
        | "delivery_uncertain"
        | "configuration_error"
        | "disabled"
        | "render_failed";
      providerMessageId?: never;
      errorCode: string;
    };

export async function completeParentOtpV2(
  client: OtpV2Client,
  deliveryAttemptId: string,
  outcome: ParentOtpV2Outcome,
) {
  const { data, error } = await client.rpc(
    "complete_parent_otp_delivery_v1",
    {
      p_delivery_attempt_id: deliveryAttemptId,
      p_outcome: outcome.outcome,
      p_provider_http_message_id:
        outcome.outcome === "accepted"
          ? outcome.providerMessageId
          : null,
      p_error_code:
        outcome.outcome === "accepted" ? null : outcome.errorCode,
    },
  );
  if (error) throw new Error("PARENT_OTP_V2_COMPLETION_FAILED");
  const parsed = parentOtpV2CompletionSchema.safeParse(data);
  if (!parsed.success) throw new Error("PARENT_OTP_V2_COMPLETION_INVALID");
  return parsed.data;
}

export function renderParentOtpV2(
  preparation: PreparedParentOtpV2,
  code: string,
  appBaseUrl: string,
) {
  if (!/^\d{6}$/u.test(code)) throw new Error("PARENT_OTP_CODE_INVALID");
  const {
    id: _templateRevisionId,
    contentHash: _templateContentHash,
    ...source
  } = preparation.template;
  const {
    id: _brandingRevisionId,
    contentHash: _brandingContentHash,
    ...branding
  } = preparation.branding;
  void _templateRevisionId;
  void _templateContentHash;
  void _brandingRevisionId;
  void _brandingContentHash;
  return renderMailV2({
    source,
    branding,
    shortcodes: {
      club_name: branding.clubName,
      recipient_name: "ouder/verzorger",
      contact_email: branding.contactEmail,
      otp_expiry_minutes: preparation.expiresInMinutes,
      privacy_url: branding.privacyUrl,
    },
    protectedValues: {
      otp_code: { code },
      otp_validity: { minutes: preparation.expiresInMinutes },
      otp_warning: {},
    },
    appBaseUrl,
  });
}
