import {
  mailManagementResponseSchema,
  mailV2CutoverSnapshotSchema,
} from "@/lib/mail-v2-contract";
import { mailV2PreviewData, renderMailV2Body } from "@/server/email/mail-v2";
import {
  getMailV2Workspace,
  mailV2BrandingValues,
  mailV2SourceForTemplate,
} from "@/server/email/mail-v2-workspace";
import { getSupabaseServerClient } from "@/server/supabase/server";

type MailBootstrapError = {
  code: string;
  message: string;
};

/**
 * Publishes only currently unpublished drafts through the normal renderer and
 * audited database functions. Each completed template is safe to retain when a
 * later template is concurrently changed; retrying naturally continues with the
 * remaining drafts. Cutover happens only after a fresh, complete preflight.
 */
export async function prepareAndActivateMailV2(
  input: { reason: string },
  correlationId: string | null,
) {
  const workspace = await getMailV2Workspace();
  const missing = workspace.templates.filter((template) => !template.published);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const preview = mailV2PreviewData();
  const branding = mailV2BrandingValues(workspace.branding.published);

  for (const template of missing) {
    const draft = template.draft;
    if (!draft) {
      return {
        data: null,
        error: {
          code: "P0002",
          message: "MAIL_V2_TEMPLATE_DRAFT_MISSING",
        } satisfies MailBootstrapError,
      };
    }
    const source = mailV2SourceForTemplate(template, {
      subjectSource: draft.subjectSource,
      preheaderSource: draft.preheaderSource,
      bodyTipTap: draft.bodyTipTap,
    });
    const rendered = renderMailV2Body({
      source,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
    });
    const saved = await supabase.schema("app").rpc(
      "save_mail_template_draft_v1",
      {
        p_template_key: template.key,
        p_expected_hash: draft.contentHash,
        p_internal_name: draft.internalName,
        p_subject_source: draft.subjectSource,
        p_preheader_source: draft.preheaderSource,
        p_body_tiptap: draft.bodyTipTap,
        p_sanitized_html_source: rendered.html,
        p_text_fallback_source: rendered.text,
        p_correlation_id: correlationId,
      },
    );
    if (saved.error) return { data: null, error: saved.error };
    const savedRevision = mailManagementResponseSchema.safeParse(saved.data);
    if (!savedRevision.success) {
      throw new Error("MAIL_V2_MUTATION_RESPONSE_INVALID");
    }
    const published = await supabase.schema("app").rpc(
      "publish_mail_template_revision_v1",
      {
        p_revision_id: savedRevision.data.revisionId,
        p_expected_hash: savedRevision.data.contentHash,
        p_correlation_id: correlationId,
      },
    );
    if (published.error) return { data: null, error: published.error };
    if (!mailManagementResponseSchema.safeParse(published.data).success) {
      throw new Error("MAIL_V2_MUTATION_RESPONSE_INVALID");
    }
  }

  const preflight = await supabase.schema("app").rpc(
    "get_mail_v2_cutover_snapshot_v2",
  );
  if (preflight.error) return { data: null, error: preflight.error };
  const snapshot = mailV2CutoverSnapshotSchema.safeParse(preflight.data);
  if (!snapshot.success) throw new Error("MAIL_V2_CUTOVER_RESPONSE_INVALID");
  if (!snapshot.data.ready) {
    return {
      data: null,
      error: {
        code: "23514",
        message: "MAIL_V2_CUTOVER_RECONCILIATION_REQUIRED",
      } satisfies MailBootstrapError,
    };
  }
  const activated = await supabase.schema("app").rpc(
    "activate_mail_templates_v2",
    {
      p_expected_revision: snapshot.data.revision,
      p_reason: input.reason,
      p_correlation_id: correlationId,
    },
  );
  if (activated.error) return { data: null, error: activated.error };
  const result = mailV2CutoverSnapshotSchema.safeParse(activated.data);
  if (!result.success) throw new Error("MAIL_V2_CUTOVER_RESPONSE_INVALID");
  return {
    data: { ...result.data, preparedCount: missing.length },
    error: null,
  };
}
