import { parentOtpEmailTemplateSchema, type ParentOtpEmailTemplate } from "@/lib/email-contract";
import {
  parentOtpV2CompletionSchema,
  parentOtpV2PreparationSchema,
  parentOtpV3PreparationSchema,
  type PreparedParentOtpV2,
  type PreparedParentOtpV3,
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
      | "complete_parent_otp_delivery_v1"
      | "complete_parent_otp_delivery_v2",
    parameters: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

type OtpV3Client = {
  rpc(
    name: "prepare_parent_otp_delivery_v3",
    parameters: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

export async function prepareParentOtpV3(
  client: OtpV3Client,
  email: string,
  challengeId: string,
  codeHash: string,
  forceNew = false,
  expectedChallengeId: string | null = null,
) {
  if (forceNew !== Boolean(expectedChallengeId)) {
    throw new Error("PARENT_OTP_V3_EXPECTED_CHALLENGE_INVALID");
  }
  const { data, error } = await client.rpc(
    "prepare_parent_otp_delivery_v3",
    {
      p_email: email,
      p_challenge_id: challengeId,
      p_code_hash: codeHash,
      p_force_new: forceNew,
      p_actor_user_id: null,
      p_expected_challenge_id: expectedChallengeId,
    },
  );
  if (error) throw new Error("PARENT_OTP_V3_PREPARATION_FAILED");
  const parsed = parentOtpV3PreparationSchema.safeParse(data);
  if (!parsed.success) throw new Error("PARENT_OTP_V3_PREPARATION_INVALID");
  return parsed.data;
}

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
  providerEvidence?: {
    provider: "smtp" | "sendgrid";
    providerState:
      | "provider_accepted"
      | "temporary_failure"
      | "permanent_rejection"
      | "delivery_uncertain"
      | "configuration_error"
      | "disabled";
    responseCode?: string;
    enhancedStatusCode?: string;
    recipientFailure: boolean;
  },
) {
  const { data, error } = await client.rpc(
    providerEvidence
      ? "complete_parent_otp_delivery_v2"
      : "complete_parent_otp_delivery_v1",
    {
      p_delivery_attempt_id: deliveryAttemptId,
      p_outcome: outcome.outcome,
      p_provider_http_message_id:
        outcome.outcome === "accepted"
          ? outcome.providerMessageId
          : null,
      p_error_code:
        outcome.outcome === "accepted" ? null : outcome.errorCode,
      ...(providerEvidence ? {
        p_provider: providerEvidence.provider,
        p_provider_state: providerEvidence.providerState,
        p_response_code: providerEvidence.responseCode ?? null,
        p_enhanced_status_code: providerEvidence.enhancedStatusCode ?? null,
        p_recipient_failure: providerEvidence.recipientFailure,
      } : {}),
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
      otp_validity: {
        minutes: preparation.expiresInMinutes,
        requestedAt: new Date().toISOString(),
        expiresAt: new Date(
          Date.now() + preparation.expiresInMinutes * 60_000,
        ).toISOString(),
      },
      otp_warning: {},
    },
    appBaseUrl,
  });
}

export function renderParentOtpV3(
  preparation: PreparedParentOtpV3,
  code: string,
  directCredential: string,
  appBaseUrl: string,
) {
  if (!/^\d{6}$/u.test(code)) throw new Error("PARENT_OTP_CODE_INVALID");
  if (!/^v1\.[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/u.test(directCredential)) {
    throw new Error("PARENT_DIRECT_CREDENTIAL_INVALID");
  }
  const expiresAt = new Date(preparation.expiresAt);
  const requestedAt = new Date(
    Date.parse(preparation.cooldownUntil) - 90 * 1_000,
  );
  const directUrl = new URL("/login/direct", appBaseUrl);
  directUrl.hash = directCredential;
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
      otp_direct_login: {
        url: directUrl.toString(),
        label: "Direct inloggen",
      },
      otp_validity: {
        minutes: preparation.expiresInMinutes,
        requestedAt: requestedAt.toISOString(),
        expiresAt: expiresAt.toISOString(),
      },
      otp_warning: {},
    },
    appBaseUrl,
  });
}
