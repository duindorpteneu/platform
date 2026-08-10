import { unstable_noStore as noStore } from "next/cache";
import {
  mailBrandingSchema,
  mailManagementResponseSchema,
  mailV2CutoverSnapshotSchema,
  mailV2WorkspaceSchema,
  retryMailV2ProjectionResponseSchema,
  type MailBranding,
  type MailTipTapDocument,
  type MailV2CutoverSnapshot,
  type MailV2Workspace,
} from "@/lib/mail-v2-contract";
import { requireStaffRole } from "@/server/auth/staff";
import {
  mailV2PreviewData,
  renderMailV2Body,
  renderMailV2,
} from "@/server/email/mail-v2";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseServerClient } from "@/server/supabase/server";

function logWorkspaceFailure(code: string) {
  operationalLogger.error("mail_v2.workspace_load_failed", {
    code: code.toLowerCase(),
    provider: "supabase",
    route: "/backoffice/emails",
  });
}

export async function getMailV2Workspace(): Promise<MailV2Workspace> {
  noStore();
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_mail_workspace_v1");
  if (error) {
    logWorkspaceFailure(error.code || "query_failed");
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    if (error.code === "PGRST106" || error.code === "PGRST202") {
      throw new Error("MAIL_V2_SCHEMA_CONTRACT_STALE");
    }
    throw new Error("MAIL_V2_WORKSPACE_QUERY_FAILED");
  }
  const parsed = mailV2WorkspaceSchema.safeParse(data);
  if (!parsed.success) {
    logWorkspaceFailure("response_invalid");
    throw new Error("MAIL_V2_WORKSPACE_RESPONSE_INVALID");
  }
  return parsed.data;
}

export async function getMailV2CutoverSnapshot(): Promise<MailV2CutoverSnapshot> {
  noStore();
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "get_mail_v2_cutover_snapshot_v2",
  );
  if (error) {
    logWorkspaceFailure(error.code || "cutover_query_failed");
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    if (error.code === "PGRST106" || error.code === "PGRST202") {
      throw new Error("MAIL_V2_SCHEMA_CONTRACT_STALE");
    }
    throw new Error("MAIL_V2_CUTOVER_QUERY_FAILED");
  }
  const parsed = mailV2CutoverSnapshotSchema.safeParse(data);
  if (!parsed.success) {
    logWorkspaceFailure("cutover_response_invalid");
    throw new Error("MAIL_V2_CUTOVER_RESPONSE_INVALID");
  }
  return parsed.data;
}

export async function changeMailV2Cutover(
  input:
    | { action: "activate"; expectedRevision: string; reason: string }
    | { action: "pause"; reason: string },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = input.action === "activate"
    ? await supabase.schema("app").rpc("activate_mail_templates_v2", {
      p_expected_revision: input.expectedRevision,
      p_reason: input.reason,
      p_correlation_id: correlationId,
    })
    : await supabase.schema("app").rpc("pause_mail_templates_v2", {
      p_reason: input.reason,
      p_correlation_id: correlationId,
    });
  if (error) return { data: null, error };
  const parsed = mailV2CutoverSnapshotSchema.safeParse(data);
  if (!parsed.success) throw new Error("MAIL_V2_CUTOVER_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function retryMailV2Projection(
  input: {
    groupId: string;
    expectedRetryCount: number;
    reason: string;
  },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "retry_mail_v2_domain_projection_v1",
    {
      p_projection_batch_id: input.groupId,
      p_expected_retry_count: input.expectedRetryCount,
      p_reason: input.reason,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = retryMailV2ProjectionResponseSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_V2_PROJECTION_RETRY_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

function sourceForTemplate(
  template: MailV2Workspace["templates"][number],
  input: {
    subjectSource: string;
    preheaderSource: string;
    bodyTipTap: MailTipTapDocument;
  },
) {
  return {
    templateKey: template.key,
    subjectSource: input.subjectSource,
    preheaderSource: input.preheaderSource,
    bodyTipTap: input.bodyTipTap,
    allowedShortcodes: template.allowedShortcodes,
    allowedProtectedNodes: template.allowedProtectedNodes,
    requiredProtectedNodes: template.requiredProtectedNodes,
  } as const;
}

function brandingValues(
  revision: MailV2Workspace["branding"]["published"],
): MailBranding {
  const {
    id: _id,
    revision: _revision,
    status: _status,
    contentHash: _contentHash,
    creationSource: _creationSource,
    publishedBy: _publishedBy,
    publishedAt: _publishedAt,
    createdAt: _createdAt,
    updatedAt: _updatedAt,
    ...branding
  } = revision;
  void [
    _id,
    _revision,
    _status,
    _contentHash,
    _creationSource,
    _publishedBy,
    _publishedAt,
    _createdAt,
    _updatedAt,
  ];
  return branding;
}

export async function previewMailV2Template(input: {
  templateKey: MailV2Workspace["templates"][number]["key"];
  subjectSource: string;
  preheaderSource: string;
  bodyTipTap: MailTipTapDocument;
}, appBaseUrl: string) {
  const workspace = await getMailV2Workspace();
  const template = workspace.templates.find((candidate) => candidate.key === input.templateKey);
  if (!template) throw new Error("MAIL_V2_TEMPLATE_NOT_FOUND");
  const source = sourceForTemplate(template, input);
  const preview = mailV2PreviewData();
  return renderMailV2({
    source,
    branding: brandingValues(workspace.branding.published),
    shortcodes: preview.shortcodes,
    protectedValues: preview.protectedValues,
    appBaseUrl,
  });
}

export async function saveMailV2TemplateDraft(input: {
  templateKey: MailV2Workspace["templates"][number]["key"];
  expectedHash: string | null;
  internalName: string;
  subjectSource: string;
  preheaderSource: string;
  bodyTipTap: MailTipTapDocument;
}, correlationId: string | null) {
  const workspace = await getMailV2Workspace();
  const template = workspace.templates.find((candidate) => candidate.key === input.templateKey);
  if (!template) throw new Error("MAIL_V2_TEMPLATE_NOT_FOUND");
  const preview = mailV2PreviewData();
  const renderedBody = renderMailV2Body({
    source: sourceForTemplate(template, input),
    branding: brandingValues(workspace.branding.published),
    shortcodes: preview.shortcodes,
    protectedValues: preview.protectedValues,
  });
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "save_mail_template_draft_v1",
    {
      p_template_key: input.templateKey,
      p_expected_hash: input.expectedHash,
      p_internal_name: input.internalName,
      p_subject_source: input.subjectSource,
      p_preheader_source: input.preheaderSource,
      p_body_tiptap: input.bodyTipTap,
      p_sanitized_html_source: renderedBody.html,
      p_text_fallback_source: renderedBody.text,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailManagementResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("MAIL_V2_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function publishMailV2Template(
  input: { revisionId: string; expectedHash: string },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "publish_mail_template_revision_v1",
    {
      p_revision_id: input.revisionId,
      p_expected_hash: input.expectedHash,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailManagementResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("MAIL_V2_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

function relativeLuminance(hex: string) {
  const channels = [1, 3, 5].map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16) / 255);
  const normalized = channels.map((channel) => (
    channel <= 0.03928
      ? channel / 12.92
      : ((channel + 0.055) / 1.055) ** 2.4
  ));
  return 0.2126 * normalized[0] + 0.7152 * normalized[1] + 0.0722 * normalized[2];
}

export function contrastRatio(first: string, second: string) {
  const firstLuminance = relativeLuminance(first);
  const secondLuminance = relativeLuminance(second);
  const lighter = Math.max(firstLuminance, secondLuminance);
  const darker = Math.min(firstLuminance, secondLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

export function mailBrandingContrastIsValid(
  branding: Pick<MailBranding, "primaryColor" | "secondaryColor" | "accentColor">,
) {
  return [
    branding.primaryColor,
    branding.secondaryColor,
    branding.accentColor,
  ].every((color) => contrastRatio(color, "#FFFFFF") >= 4.5);
}

export async function saveMailV2BrandingDraft(
  input: Omit<MailBranding, "contrastValidated"> & { expectedHash: string | null },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const { expectedHash, ...brandingInput } = input;
  const branding = mailBrandingSchema.parse({
    ...brandingInput,
    contrastValidated: mailBrandingContrastIsValid(brandingInput),
  });
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "save_mail_branding_draft_v1",
    {
      p_expected_hash: expectedHash,
      p_branding: branding,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailManagementResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("MAIL_V2_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function publishMailV2Branding(
  input: { revisionId: string; expectedHash: string },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_V2_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "publish_mail_branding_revision_v2",
    {
      p_revision_id: input.revisionId,
      p_expected_hash: input.expectedHash,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailManagementResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("MAIL_V2_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}
