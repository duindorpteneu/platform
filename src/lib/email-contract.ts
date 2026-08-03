import { z } from "zod";
import {
  mailTemplateKeySchema as mailV2TemplateKeySchema,
  mailV2DomainTemplateKeySchema,
} from "@/lib/mail-v2-contract";

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });

export const emailTemplateKeySchema = z.enum([
  "verification_code",
  "portal_access_invite",
  "payment_request",
  "payment_received",
  "ready_for_pickup",
  "payment_reminder",
  "qr_code_resent",
]);
export const bulkEmailTemplateKeySchema = z.enum(["payment_reminder", "ready_for_pickup"]);
export const emailJobStatusSchema = z.enum([
  "queued",
  "processing",
  "retry",
  "sent",
  "failed",
  "delivery_uncertain",
  "superseded",
]);
export const emailDeliveryStatusSchema = z.enum(["delivered", "bounced", "deferred", "dropped", "failed"]);
export const orderLineEmailStatusSchema = z.enum(["backorder", "ready_for_pickup", "picked_up"]);

const emailTemplateSchema = z.object({
  id: uuid,
  key: emailTemplateKeySchema,
  subjectSource: z.string().min(3).max(180),
  bodySource: z.string().min(10).max(10_000),
  allowedShortcodes: z.array(z.string().regex(/^{{[a-z_]+}}$/)).min(1).max(32),
  active: z.boolean(),
  version: z.number().int().positive(),
  updatedAt: timestamp,
}).strict();

const emailOrderLineSchema = z.object({
  orderLineId: uuid,
  article: z.string().min(1).max(160),
  size: z.string().min(1).max(80),
  quantity: z.number().int().min(1).max(25),
  status: orderLineEmailStatusSchema,
}).strict();

const emailWorkspaceOrderSchema = z.object({
  orderId: uuid,
  memberName: z.string().min(1).max(320),
  relationNumber: z.string().min(1).max(120).nullable(),
  team: z.string().min(1).max(160),
  season: z.string().min(1).max(120),
  amountDueCents: z.number().int().nonnegative(),
  paymentReminderEligible: z.boolean(),
  readyForPickupEligible: z.boolean(),
  lines: z.array(emailOrderLineSchema).max(25),
}).strict();

const emailWorkspaceJobBase = {
  id: uuid,
  templateKey: emailTemplateKeySchema,
  status: emailJobStatusSchema,
  attempts: z.number().int().min(0).max(5),
  deliveryStatus: emailDeliveryStatusSchema.nullable(),
  availableAt: timestamp,
  sentAt: timestamp.nullable(),
  createdAt: timestamp,
  updatedAt: timestamp,
  claimedAt: timestamp.nullable(),
  recoverable: z.boolean(),
};

const emailWorkspaceJobSchema = z.discriminatedUnion("contextKind", [
  z.object({
    ...emailWorkspaceJobBase,
    contextKind: z.literal("order"),
    orderId: uuid,
  }).strict(),
  z.object({
    ...emailWorkspaceJobBase,
    contextKind: z.literal("portal_access"),
    orderId: z.null(),
    templateKey: z.literal("portal_access_invite"),
  }).strict(),
  z.object({
    ...emailWorkspaceJobBase,
    contextKind: z.literal("fulfilment"),
    orderId: z.null(),
    templateKey: mailV2TemplateKeySchema.extract([
      "partial_pickup",
      "package_complete",
    ]),
  }).strict(),
  z.object({
    ...emailWorkspaceJobBase,
    contextKind: z.literal("mail_v2"),
    orderId: z.null(),
    templateKey: mailV2DomainTemplateKeySchema,
  }).strict(),
]);

export const emailWorkspaceSchema = z.object({
  recoveryAllowed: z.boolean(),
  templateKeys: z.array(emailTemplateKeySchema).min(6).max(7),
  templates: z.array(emailTemplateSchema).min(6).max(7),
  batches: z.array(z.object({
    id: uuid,
    batchKey: z.string().min(8).max(160),
    templateKey: bulkEmailTemplateKeySchema,
    selectedCount: z.number().int().min(1).max(2_000),
    createdAt: timestamp,
  }).strict()).max(25),
  jobs: z.array(emailWorkspaceJobSchema).max(100),
  orders: z.array(emailWorkspaceOrderSchema).max(20_000),
}).strict().superRefine((value, context) => {
  const keys = new Set(value.templateKeys);
  if (keys.size !== value.templateKeys.length
    || value.templates.length !== value.templateKeys.length
    || value.templates.some((template) => !keys.has(template.key))
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["templates"],
      message: "Templatecatalogus en templates komen niet overeen.",
    });
  }
});

export const updateEmailTemplateRequestSchema = z.object({
  templateId: uuid,
  subjectSource: z.string().trim().min(3).max(180).refine((value) => !/[\r\n<>]/.test(value)),
  bodySource: z.string().trim().min(10).max(10_000).refine((value) => !/[<>]/.test(value)),
  expectedVersion: z.number().int().positive(),
}).strict();

export const previewEmailTemplateRequestSchema = updateEmailTemplateRequestSchema.omit({ expectedVersion: true });

export const updateEmailTemplateResponseSchema = z.object({
  templateId: uuid,
  templateKey: emailTemplateKeySchema,
  version: z.number().int().positive(),
}).strict();

const uniqueOrderIds = z.array(uuid).min(1).max(2_000).refine((values) => new Set(values).size === values.length, "Bestellingen moeten uniek zijn.");

export const emailBulkRequestSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("preview"), templateKey: bulkEmailTemplateKeySchema, orderIds: uniqueOrderIds }).strict(),
  z.object({ action: z.literal("confirm"), previewToken: z.string().min(64).max(250_000) }).strict(),
]);

export const createEmailBulkResponseSchema = z.object({
  batchId: uuid,
  templateKey: bulkEmailTemplateKeySchema,
  jobCount: z.number().int().min(1).max(2_000),
  reused: z.boolean(),
}).strict();

export const emailRecoveryResolutionSchema = z.enum(["confirm_sent", "retry_proven_not_accepted"]);
export const emailRecoveryReasonSchema = z.enum(["provider_confirmed_accepted", "provider_confirmed_not_accepted"]);
const providerEvidenceSchema = z.string().trim().min(8).max(120).regex(/^[A-Za-z0-9][A-Za-z0-9._:/-]*$/);

export const recoverEmailJobRequestSchema = z.object({
  expectedUpdatedAt: timestamp,
  resolution: emailRecoveryResolutionSchema,
  reason: emailRecoveryReasonSchema,
  providerEvidenceRef: providerEvidenceSchema,
  providerMessageId: z.string().trim().min(3).max(240).nullable(),
  attestedNotAccepted: z.boolean(),
}).strict().superRefine((value, context) => {
  if (value.resolution === "confirm_sent") {
    if (value.reason !== "provider_confirmed_accepted") context.addIssue({ code: z.ZodIssueCode.custom, path: ["reason"], message: "Provideracceptatie is vereist." });
    if (!value.providerMessageId) context.addIssue({ code: z.ZodIssueCode.custom, path: ["providerMessageId"], message: "Providerbericht-ID is vereist." });
    if (value.attestedNotAccepted) context.addIssue({ code: z.ZodIssueCode.custom, path: ["attestedNotAccepted"], message: "Tegenstrijdige bevestiging." });
  } else {
    if (value.reason !== "provider_confirmed_not_accepted") context.addIssue({ code: z.ZodIssueCode.custom, path: ["reason"], message: "Providerweigering is vereist." });
    if (value.providerMessageId) context.addIssue({ code: z.ZodIssueCode.custom, path: ["providerMessageId"], message: "Een providerbericht-ID bewijst acceptatie." });
    if (!value.attestedNotAccepted) context.addIssue({ code: z.ZodIssueCode.custom, path: ["attestedNotAccepted"], message: "Expliciete attestatie is vereist." });
  }
});

export const recoverEmailJobResponseSchema = z.object({
  jobId: uuid,
  status: z.enum(["sent", "retry"]),
  attempts: z.number().int().min(1).max(5),
  updatedAt: timestamp,
}).strict();

const claimedEmailLineSchema = z.object({
  orderLineId: uuid,
  article: z.string().min(1).max(160),
  size: z.string().min(1).max(80),
  quantity: z.number().int().min(1).max(25),
  status: orderLineEmailStatusSchema,
}).strict();

const claimedEmailJobBase = {
  id: uuid,
  deliveryAttemptId: uuid,
  kind: z.enum(["transactional", "bulk"]),
  recipientEmail: z.string().min(1).max(320),
  templateVersion: z.number().int().positive(),
  subjectSource: z.string().min(3).max(180),
  bodySource: z.string().min(10).max(10_000),
  allowedShortcodes: z.array(z.string().regex(/^{{[a-z_]+}}$/)).min(1).max(32),
  attempt: z.number().int().min(1).max(5),
};

const claimedOrderEmailJobSchema = z.object({
  ...claimedEmailJobBase,
  contextKind: z.literal("order"),
  templateKey: emailTemplateKeySchema.exclude(["verification_code", "portal_access_invite"]),
  orderId: uuid,
  parentAccountId: z.null(),
  payload: z.object({
    orderId: uuid,
    memberId: uuid,
    firstName: z.string().min(1).max(160),
    fullName: z.string().min(1).max(320),
    team: z.string().max(160).nullable(),
    relationNumber: z.string().min(1).max(120).nullable(),
    season: z.string().min(1).max(120),
    amountCents: z.number().int().nonnegative(),
    clubName: z.string().min(1).max(160),
    contactEmail: z.string().max(320).nullable(),
    pickupLocation: z.string().min(1).max(500).nullable(),
    qrVersion: z.number().int().positive().nullable(),
    articles: z.array(claimedEmailLineSchema).max(25),
    articlesReady: z.array(claimedEmailLineSchema).max(25),
    articlesBackorder: z.array(claimedEmailLineSchema).max(25),
  }).strict(),
}).strict();

const claimedPortalAccessEmailJobSchema = z.object({
  ...claimedEmailJobBase,
  kind: z.literal("transactional"),
  contextKind: z.literal("portal_access"),
  templateKey: z.literal("portal_access_invite"),
  orderId: z.null(),
  parentAccountId: uuid,
  payload: z.object({
    parentAccountId: uuid,
    clubName: z.string().min(1).max(160),
    contactEmail: z.string().email().max(320).nullable(),
  }).strict(),
}).strict();

const claimedFulfilmentEmailJobSchema = z.object({
  id: uuid,
  deliveryAttemptId: uuid,
  kind: z.literal("transactional"),
  contextKind: z.literal("fulfilment"),
  recipientEmail: z.string().trim().email().max(320),
  templateKey: mailV2TemplateKeySchema.extract([
    "partial_pickup",
    "package_complete",
  ]),
  templateRevisionId: uuid,
  brandingRevisionId: uuid,
  subject: z.string().trim().min(1).max(200).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  preheader: z.string().trim().min(1).max(240).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  html: z.string().trim().min(1).max(50_000),
  text: z.string().trim().min(1).max(20_000),
  fromName: z.string().trim().min(3).max(120).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  fromEmail: z.string().trim().email().max(320),
  replyToEmail: z.string().trim().email().max(320),
  renderHash: z.string().regex(/^[0-9a-f]{64}$/u),
  parentAccountId: uuid,
  seasonId: uuid,
  eventCount: z.number().int().min(1).max(10),
  attempt: z.number().int().min(1).max(5),
}).strict();

const claimedMailV2DomainEmailJobSchema = z.object({
  id: uuid,
  deliveryAttemptId: uuid,
  kind: z.enum(["transactional", "bulk"]),
  contextKind: z.literal("mail_v2"),
  recipientEmail: z.string().trim().email().max(320),
  templateKey: mailV2DomainTemplateKeySchema,
  templateRevisionId: uuid,
  brandingRevisionId: uuid,
  subject: z.string().trim().min(1).max(200).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  preheader: z.string().trim().min(1).max(240).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  html: z.string().trim().min(1).max(50_000),
  text: z.string().trim().min(1).max(20_000),
  fromName: z.string().trim().min(3).max(120).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  fromEmail: z.string().trim().email().max(320),
  replyToEmail: z.string().trim().email().max(320),
  renderHash: z.string().regex(/^[0-9a-f]{64}$/u),
  parentAccountId: uuid.nullable(),
  seasonId: uuid,
  eventCount: z.number().int().min(1).max(100),
  attempt: z.number().int().min(1).max(5),
}).strict();

export const claimedEmailJobSchema = z.discriminatedUnion("contextKind", [
  claimedOrderEmailJobSchema,
  claimedPortalAccessEmailJobSchema,
  claimedFulfilmentEmailJobSchema,
  claimedMailV2DomainEmailJobSchema,
]).superRefine((value, context) => {
  if (value.contextKind === "order" && value.orderId !== value.payload.orderId) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["payload", "orderId"],
      message: "Ordercontext komt niet overeen.",
    });
  }
  if (value.contextKind === "portal_access" && value.parentAccountId !== value.payload.parentAccountId) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["payload", "parentAccountId"],
      message: "Ouderaccountcontext komt niet overeen.",
    });
  }
  if (
    value.contextKind === "mail_v2"
    && (
      (value.templateKey === "internal_email_failure")
      !== (value.parentAccountId === null)
    )
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["parentAccountId"],
      message: "Interne en oudergerichte mailcontext komen niet overeen.",
    });
  }
  if (
    value.contextKind === "mail_v2"
    && value.templateKey === "internal_email_failure"
    && value.kind !== "transactional"
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["kind"],
      message: "Interne foutmeldingen zijn uitsluitend transactioneel.",
    });
  }
});

export const emailJobClaimResponseSchema = z.object({
  claimToken: uuid,
  jobs: z.array(claimedEmailJobSchema).max(25),
}).strict();

export const parentOtpEmailTemplateSchema = z.object({
  templateKey: z.literal("verification_code"),
  templateVersion: z.number().int().positive(),
  subjectSource: z.string().min(3).max(180),
  bodySource: z.string().min(10).max(10_000),
  allowedShortcodes: z.array(z.string().regex(/^{{[a-z_]+}}$/)).min(1).max(14),
  clubName: z.string().min(1).max(160),
  contactEmail: z.string().email().max(320).nullable(),
}).strict();

export const emailTemplateLabels: Record<z.infer<typeof emailTemplateKeySchema>, string> = {
  verification_code: "Verificatiecode",
  portal_access_invite: "Portaaltoegang geactiveerd",
  payment_request: "Betalingsverzoek",
  payment_received: "Betaling ontvangen",
  ready_for_pickup: "Artikelen af te halen",
  payment_reminder: "Betalingsherinnering",
  qr_code_resent: "QR-code opnieuw verzonden",
};

export type EmailWorkspace = z.infer<typeof emailWorkspaceSchema>;
export type EmailTemplateKey = z.infer<typeof emailTemplateKeySchema>;
export type BulkEmailTemplateKey = z.infer<typeof bulkEmailTemplateKeySchema>;
export type ClaimedEmailJob = z.infer<typeof claimedEmailJobSchema>;
export type ParentOtpEmailTemplate = z.infer<typeof parentOtpEmailTemplateSchema>;
export type RecoverEmailJobRequest = z.infer<typeof recoverEmailJobRequestSchema>;
