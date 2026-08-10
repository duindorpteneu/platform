import { unstable_noStore as noStore } from "next/cache";
import {
  mailV2CampaignConfirmSchema,
  mailV2CampaignPreflightRpcSchema,
  mailV2CampaignPreviewSchema,
  mailV2CampaignWorkspaceSchema,
  type MailV2CampaignTemplateKey,
  type MailV2CampaignWorkspace,
} from "@/lib/mail-v2-contract";
import { getServerEnv } from "@/lib/env";
import { requireStaffRole } from "@/server/auth/staff";
import { renderMailV2DomainProjectionGroup } from "@/server/email/mail-v2-projector";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getMailV2CampaignWorkspace(): Promise<
  MailV2CampaignWorkspace
> {
  noStore();
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_CAMPAIGN_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "get_mail_v2_campaign_workspace_v1",
  );
  if (error) {
    if (error.code === "42501") {
      throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    }
    throw new Error("MAIL_V2_CAMPAIGN_WORKSPACE_QUERY_FAILED");
  }
  const parsed = mailV2CampaignWorkspaceSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_V2_CAMPAIGN_WORKSPACE_RESPONSE_INVALID");
  }
  return parsed.data;
}

export async function previewMailV2Campaign(
  input: {
    templateKey: MailV2CampaignTemplateKey;
    targetIds: string[];
    requestId: string;
  },
) {
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_CAMPAIGN_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "preview_mail_v2_campaign_v1",
    {
      p_template_key: input.templateKey,
      p_target_ids: input.targetIds,
      p_request_id: input.requestId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailV2CampaignPreflightRpcSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_V2_CAMPAIGN_PREVIEW_RESPONSE_INVALID");
  }
  const { previewGroup, ...preflight } = parsed.data;
  const rendered = previewGroup
    ? renderMailV2DomainProjectionGroup(
      previewGroup,
      getServerEnv().APP_BASE_URL,
    )
    : null;
  const response = mailV2CampaignPreviewSchema.safeParse({
    ...preflight,
    preview: rendered
      ? {
        subject: rendered.subject,
        preheader: rendered.preheader,
        html: rendered.html,
        text: rendered.text,
      }
      : null,
  });
  if (!response.success) {
    throw new Error("MAIL_V2_CAMPAIGN_PREVIEW_RENDER_INVALID");
  }
  return { data: response.data, error: null };
}

export async function confirmMailV2Campaign(
  input: {
    preflightId: string;
    expectedRevision: string;
    requestId: string;
  },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_CAMPAIGN_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "confirm_mail_v2_campaign_v1",
    {
      p_preflight_id: input.preflightId,
      p_expected_revision: input.expectedRevision,
      p_request_id: input.requestId,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailV2CampaignConfirmSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_V2_CAMPAIGN_CONFIRM_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}
