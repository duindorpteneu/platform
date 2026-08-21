import type { PreparedParentOtpV3 } from "@/lib/mail-v2-contract";
import {
  deriveParentCode,
  deriveParentDirectCredential,
} from "@/server/auth/parent";
import {
  authorizeParentOtpV2,
  completeParentOtpV2,
  renderParentOtpV3,
} from "@/server/email/otp";
import { sendParentOtpV2Email } from "@/server/email/provider";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export type ParentOtpDeliveryResult = {
  outcome:
    | "provider_accepted"
    | "provider_rejected"
    | "delivery_uncertain"
    | "configuration_error"
    | "disabled"
    | "render_failed";
};

export async function deliverPreparedParentOtpV3(
  admin: NonNullable<ReturnType<typeof getSupabaseAdminClient>>,
  preparation: PreparedParentOtpV3,
  recipientEmail: string,
  appBaseUrl: string,
): Promise<ParentOtpDeliveryResult> {
  const appClient = admin.schema("app");
  const provider = process.env.EMAIL_PROVIDER === "sendgrid"
    ? "sendgrid" as const
    : process.env.EMAIL_PROVIDER === "smtp"
      ? "smtp" as const
      : null;
  try {
    if (!await authorizeParentOtpV2(
      appClient,
      preparation.deliveryAttemptId,
    )) {
      await completeParentOtpV2(appClient, preparation.deliveryAttemptId, {
        outcome: "disabled",
        errorCode: "send_authorization_denied",
      }, provider ? {
        provider,
        providerState: "disabled",
        recipientFailure: false,
      } : undefined);
      return { outcome: "disabled" };
    }

    let message: ReturnType<typeof renderParentOtpV3>;
    try {
      message = renderParentOtpV3(
        preparation,
        deriveParentCode(preparation.challengeId),
        deriveParentDirectCredential(preparation.challengeId),
        appBaseUrl,
      );
    } catch {
      await completeParentOtpV2(appClient, preparation.deliveryAttemptId, {
        outcome: "render_failed",
        errorCode: "render_failed",
      });
      return { outcome: "render_failed" };
    }

    const delivery = await sendParentOtpV2Email({
      deliveryAttemptId: preparation.deliveryAttemptId,
      recipientEmail,
      subject: message.subject,
      text: message.text,
      html: message.html,
      fromName: message.fromName,
      fromEmail: message.fromEmail,
      replyToEmail: message.replyToEmail,
    });
    await completeParentOtpV2(
      appClient,
      preparation.deliveryAttemptId,
      delivery.delivered
        ? {
            outcome: "accepted",
            providerMessageId: delivery.providerMessageId,
          }
        : { outcome: delivery.reason, errorCode: delivery.reason },
      provider ? {
        provider,
        providerState: delivery.delivered
          ? "provider_accepted"
          : delivery.deliveryState ?? (
              delivery.reason === "delivery_uncertain"
                ? "delivery_uncertain"
                : delivery.reason === "configuration_error"
                  ? "configuration_error"
                  : delivery.reason === "disabled"
                    ? "disabled"
                    : delivery.outcome === "retry"
                      ? "temporary_failure"
                      : "permanent_rejection"
            ),
        responseCode: delivery.providerCode,
        enhancedStatusCode: delivery.enhancedStatusCode,
        recipientFailure: delivery.delivered
          ? false
          : delivery.recipientFailure ?? false,
      } : undefined,
    );
    return {
      outcome: delivery.delivered ? "provider_accepted" : delivery.reason,
    };
  } catch {
    // The immutable attempt remains observable by operational health. Never
    // return or log the recipient, code, direct proof or rendered message.
    return { outcome: "delivery_uncertain" };
  }
}
