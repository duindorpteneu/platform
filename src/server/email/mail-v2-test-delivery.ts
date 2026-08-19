import { z } from "zod";
import {
  mailV2TestCompletionSchema,
  mailV2TestPreparationSchema,
  mailV2TestResponseSchema,
  type MailTemplateKey,
  type MailV2TestResponse,
} from "@/lib/mail-v2-contract";
import { requireStaffRole } from "@/server/auth/staff";
import {
  mailV2PreviewData,
  renderMailV2,
} from "@/server/email/mail-v2";
import {
  emailSmokeRecipient,
  sendMailV2TestEmail,
  type EmailDeliveryResult,
} from "@/server/email/provider";
import { getSupabaseServerClient } from "@/server/supabase/server";

const fixedRecipientSchema = z.string().trim().email().max(320);

type TestOutcome = Exclude<MailV2TestResponse["status"], "prepared">;

function providerOutcome(result: EmailDeliveryResult): TestOutcome {
  if (result.delivered) return "accepted";
  if (result.reason === "delivery_uncertain") return "delivery_uncertain";
  if (result.reason === "configuration_error") return "configuration_error";
  if (result.reason === "disabled") return "disabled";
  return "provider_rejected";
}

async function finalize(
  deliveryId: string,
  outcome: TestOutcome,
  providerMessageId: string | null,
  correlationId: string | null,
) {
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_TEST_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "finalize_mail_test_delivery_v2",
    {
      p_delivery_id: deliveryId,
      p_outcome: outcome,
      p_provider_http_message_id: providerMessageId,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailV2TestCompletionSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_V2_TEST_FINALIZE_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function sendMailV2TestDelivery(
  input: {
    requestId: string;
    templateKey: MailTemplateKey;
    expectedContentHash: string;
  },
  correlationId: string | null,
  appBaseUrl: string,
): Promise<{
  data: MailV2TestResponse | null;
  error: { code?: string } | null;
}> {
  await requireStaffRole(["beheerder"]);
  const recipient = fixedRecipientSchema.safeParse(
    emailSmokeRecipient(),
  );
  if (!recipient.success) {
    throw new Error("MAIL_V2_TEST_RECIPIENT_UNAVAILABLE");
  }

  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_TEST_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "prepare_mail_test_delivery_v1",
    {
      p_request_id: input.requestId,
      p_template_key: input.templateKey,
      p_expected_content_hash: input.expectedContentHash,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const prepared = mailV2TestPreparationSchema.safeParse(data);
  if (!prepared.success) {
    throw new Error("MAIL_V2_TEST_PREPARE_RESPONSE_INVALID");
  }

  if (prepared.data.reused) {
    return {
      data: mailV2TestResponseSchema.parse(prepared.data),
      error: null,
    };
  }

  let rendered: ReturnType<typeof renderMailV2>;
  try {
    const preview = mailV2PreviewData();
    rendered = renderMailV2({
      source: prepared.data.template.source,
      branding: prepared.data.branding.values,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
      appBaseUrl,
    });
  } catch {
    const completion = await finalize(
      prepared.data.deliveryId,
      "render_failed",
      null,
      correlationId,
    );
    if (completion.error) {
      throw new Error("MAIL_V2_TEST_FINALIZE_UNCERTAIN");
    }
    return { data: completion.data, error: null };
  }

  const providerResult = await sendMailV2TestEmail({
    testDeliveryId: prepared.data.deliveryId,
    subject: rendered.subject,
    text: rendered.text,
    html: rendered.html,
    fromName: rendered.fromName,
    fromEmail: rendered.fromEmail,
    replyToEmail: rendered.replyToEmail,
  });
  const completion = await finalize(
    prepared.data.deliveryId,
    providerOutcome(providerResult),
    providerResult.delivered
      ? providerResult.providerMessageId
      : null,
    correlationId,
  );
  if (completion.error) {
    throw new Error("MAIL_V2_TEST_FINALIZE_UNCERTAIN");
  }
  return { data: completion.data, error: null };
}
