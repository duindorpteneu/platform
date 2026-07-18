import { unstable_noStore as noStore } from "next/cache";
import { bulkEmailTemplateKeySchema, createEmailBulkResponseSchema, emailWorkspaceSchema, type BulkEmailTemplateKey, type ClaimedEmailJob, type EmailWorkspace } from "@/lib/email-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { fictionalEmailPreviewValues, renderEmailTemplate, validateTemplateForPurpose } from "@/server/email/templates";
import { getSupabaseServerClient } from "@/server/supabase/server";

export async function getEmailWorkspace() {
  noStore();
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("EMAIL_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("get_email_workspace");
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("EMAIL_WORKSPACE_QUERY_FAILED");
  }
  const parsed = emailWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("EMAIL_WORKSPACE_RESPONSE_INVALID");
  return { workspace: parsed.data, staff };
}

export function templateShortcodeNames(template: EmailWorkspace["templates"][number]) {
  return template.allowedShortcodes.map((shortcode) => shortcode.slice(2, -2));
}

export function renderFictionalTemplatePreview(workspace: EmailWorkspace, templateKey: BulkEmailTemplateKey) {
  const template = workspace.templates.find((candidate) => candidate.key === templateKey && candidate.active);
  if (!template) throw new Error("EMAIL_TEMPLATE_NOT_ACTIVE");
  return renderEmailTemplate(template.subjectSource, template.bodySource, templateShortcodeNames(template), fictionalEmailPreviewValues());
}

export function assertEligibleBulkSelection(workspace: EmailWorkspace, templateKey: BulkEmailTemplateKey, orderIds: string[]) {
  const selected = new Set(orderIds);
  const orders = workspace.orders.filter((order) => selected.has(order.orderId));
  if (orders.length !== orderIds.length) throw new Error("EMAIL_BULK_SELECTION_NOT_VISIBLE");
  const eligible = templateKey === "payment_reminder"
    ? orders.every((order) => order.paymentReminderEligible)
    : orders.every((order) => order.readyForPickupEligible);
  if (!eligible) throw new Error("EMAIL_BULK_SELECTION_NOT_ELIGIBLE");
  return orders;
}

export async function updateEmailTemplate(input: { templateId: string; subjectSource: string; bodySource: string; expectedVersion: number }) {
  const { workspace } = await getEmailWorkspace();
  const template = workspace.templates.find((candidate) => candidate.id === input.templateId);
  if (!template) throw new Error("EMAIL_TEMPLATE_NOT_FOUND");
  validateTemplateForPurpose(template.key, input.subjectSource, input.bodySource, templateShortcodeNames(template));
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("EMAIL_DATABASE_UNAVAILABLE");
  return supabase.schema("app").rpc("update_email_template", {
    p_template_id: input.templateId,
    p_subject_source: input.subjectSource,
    p_body_source: input.bodySource,
    p_expected_version: input.expectedVersion,
  });
}

export async function createEmailBulk(templateKey: string, orderIds: string[], batchKey: string) {
  const parsedKey = bulkEmailTemplateKeySchema.parse(templateKey);
  const { workspace } = await getEmailWorkspace();
  assertEligibleBulkSelection(workspace, parsedKey, orderIds);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("EMAIL_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc("create_email_bulk", {
    p_template_key: parsedKey,
    p_order_ids: orderIds,
    p_batch_key: batchKey,
  });
  if (error) return { data: null, error };
  const response = createEmailBulkResponseSchema.safeParse(data);
  if (!response.success) throw new Error("EMAIL_BULK_RESPONSE_INVALID");
  return { data: response.data, error: null };
}

function formatArticleLines(lines: ClaimedEmailJob["payload"]["articles"]) {
  if (lines.length === 0) return "Geen";
  return lines.map((line) => `${line.article} (${line.size})${line.quantity > 1 ? ` × ${line.quantity}` : ""}`).join(", ");
}

export function renderClaimedEmailJob(job: ClaimedEmailJob, appBaseUrl: string) {
  const baseUrl = new URL(appBaseUrl);
  const paymentUrl = new URL(`/betaling/${job.orderId}`, baseUrl).toString();
  const portalUrl = new URL("/mijn-tenue", baseUrl).toString();
  return renderEmailTemplate(
    job.subjectSource,
    job.bodySource,
    job.allowedShortcodes.map((shortcode) => shortcode.slice(2, -2)),
    {
      voornaam: job.payload.firstName,
      volledige_naam: job.payload.fullName,
      team: job.payload.team ?? "Niet opgegeven",
      relatienummer: job.payload.relationNumber,
      seizoen: job.payload.season,
      bedrag: new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(job.payload.amountCents / 100),
      betaallink: paymentUrl,
      qr_code: job.payload.qrVersion ? `Beschikbaar via ${portalUrl}` : "Beschikbaar na ontvangst van de betaling",
      artikelen_af_te_halen: formatArticleLines(job.payload.articlesReady),
      artikelen_nalevering: formatArticleLines(job.payload.articlesBackorder),
      afhaallocatie: job.payload.pickupLocation ?? "Nog niet ingesteld",
      clubnaam: job.payload.clubName,
      contact_email: job.payload.contactEmail ?? "Nog niet ingesteld",
      verificatiecode: "",
    },
  );
}
