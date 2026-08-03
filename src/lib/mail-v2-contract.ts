import { z } from "zod";

export const MAIL_TEMPLATE_KEYS = [
  "portal_access_invite",
  "portal_access_reminder",
  "login_otp",
  "size_fill_request",
  "size_fill_reminder",
  "size_review_request",
  "size_review_reminder",
  "size_confirmed",
  "payment_request",
  "payment_reminder",
  "payment_received_waiting_stock",
  "available_payment_required",
  "pickup_ready",
  "pickup_reminder",
  "out_of_stock",
  "back_in_stock",
  "partial_pickup",
  "package_complete",
  "internal_email_failure",
] as const;

export const MAIL_SHORTCODE_KEYS = [
  "club_name",
  "recipient_name",
  "member_first_name",
  "member_full_name",
  "team_name",
  "season_name",
  "package_name",
  "package_amount",
  "payment_url",
  "portal_url",
  "size_confirm_url",
  "pickup_name",
  "pickup_address",
  "contact_email",
  "privacy_url",
  "otp_expiry_minutes",
] as const;

export const MAIL_PROTECTED_NODE_KEYS = [
  "portal_route",
  "otp_code",
  "otp_validity",
  "otp_warning",
  "size_table",
  "size_action",
  "payment_summary",
  "payment_action",
  "ready_items",
  "stock_items",
  "picked_up_items",
  "remaining_items",
  "full_package",
  "pickup_location",
  "pickup_qr",
  "failure_reference",
] as const;

export const mailTemplateKeySchema = z.enum(MAIL_TEMPLATE_KEYS);
export const mailShortcodeKeySchema = z.enum(MAIL_SHORTCODE_KEYS);
export const mailProtectedNodeKeySchema = z.enum(MAIL_PROTECTED_NODE_KEYS);
export type MailTemplateKey = z.infer<typeof mailTemplateKeySchema>;
export type MailShortcodeKey = z.infer<typeof mailShortcodeKeySchema>;
export type MailProtectedNodeKey = z.infer<typeof mailProtectedNodeKeySchema>;

const linkMarkSchema = z.object({
  type: z.literal("link"),
  attrs: z.object({
    href: z.string().trim().min(9).max(2_048),
  }).strict(),
}).strict();

const boldMarkSchema = z.object({
  type: z.literal("bold"),
}).strict();

const italicMarkSchema = z.object({
  type: z.literal("italic"),
}).strict();

export const mailMarkSchema = z.discriminatedUnion("type", [
  linkMarkSchema,
  boldMarkSchema,
  italicMarkSchema,
]);
export type MailMark = z.infer<typeof mailMarkSchema>;

export type MailTextNode = {
  type: "text";
  text: string;
  marks?: MailMark[];
};

export type MailShortcodeNode = {
  type: "shortcode";
  attrs: { key: MailShortcodeKey };
};

export type MailHardBreakNode = { type: "hardBreak" };
export type MailInlineNode = MailTextNode | MailShortcodeNode | MailHardBreakNode;

export type MailParagraphNode = {
  type: "paragraph";
  content: MailInlineNode[];
};

export type MailHeadingNode = {
  type: "heading";
  attrs: { level: 2 | 3 };
  content: MailInlineNode[];
};

export type MailListItemNode = {
  type: "listItem";
  content: Array<MailParagraphNode | MailListNode>;
};

export type MailListNode =
  | { type: "bulletList"; content: MailListItemNode[] }
  | { type: "orderedList"; content: MailListItemNode[] };

export type MailProtectedBlockNode = {
  type: "protectedBlock";
  attrs: { kind: MailProtectedNodeKey };
};

export type MailBlockNode =
  | MailParagraphNode
  | MailHeadingNode
  | MailListNode
  | MailProtectedBlockNode;

export type MailTipTapDocument = {
  type: "doc";
  content: MailBlockNode[];
};

const mailTextNodeSchema: z.ZodType<MailTextNode> = z.object({
  type: z.literal("text"),
  text: z.string().min(1).max(4_000).refine(
    (value) => !/[\u0000-\u001f\u007f]/u.test(value) && !/\{\{|\}\}/u.test(value),
    "Tekst bevat ongeldige controletekens of shortcode-syntax.",
  ),
  marks: z.array(mailMarkSchema).max(4).optional(),
}).strict().superRefine((value, context) => {
  if (value.marks && new Set(value.marks.map((mark) => mark.type)).size !== value.marks.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["marks"],
      message: "Een markering mag niet dubbel voorkomen.",
    });
  }
});

const mailShortcodeNodeSchema: z.ZodType<MailShortcodeNode> = z.object({
  type: z.literal("shortcode"),
  attrs: z.object({ key: mailShortcodeKeySchema }).strict(),
}).strict();

const mailHardBreakNodeSchema: z.ZodType<MailHardBreakNode> = z.object({
  type: z.literal("hardBreak"),
}).strict();

const mailInlineNodeSchema: z.ZodType<MailInlineNode> = z.union([
  mailTextNodeSchema,
  mailShortcodeNodeSchema,
  mailHardBreakNodeSchema,
]);

const mailParagraphNodeSchema: z.ZodType<MailParagraphNode> = z.object({
  type: z.literal("paragraph"),
  content: z.array(mailInlineNodeSchema).max(100),
}).strict();

const mailHeadingNodeSchema: z.ZodType<MailHeadingNode> = z.object({
  type: z.literal("heading"),
  attrs: z.object({ level: z.union([z.literal(2), z.literal(3)]) }).strict(),
  content: z.array(mailInlineNodeSchema).max(100),
}).strict();

const mailListItemNodeSchema: z.ZodType<MailListItemNode> = z.lazy(() => z.object({
  type: z.literal("listItem"),
  content: z.array(z.union([mailParagraphNodeSchema, mailListNodeSchema])).min(1).max(100),
}).strict());

const mailListNodeSchema: z.ZodType<MailListNode> = z.lazy(() => z.union([
  z.object({
    type: z.literal("bulletList"),
    content: z.array(mailListItemNodeSchema).min(1).max(100),
  }).strict(),
  z.object({
    type: z.literal("orderedList"),
    content: z.array(mailListItemNodeSchema).min(1).max(100),
  }).strict(),
]));

const mailProtectedBlockNodeSchema: z.ZodType<MailProtectedBlockNode> = z.object({
  type: z.literal("protectedBlock"),
  attrs: z.object({ kind: mailProtectedNodeKeySchema }).strict(),
}).strict();

const mailBlockNodeSchema: z.ZodType<MailBlockNode> = z.lazy(() => z.union([
  mailParagraphNodeSchema,
  mailHeadingNodeSchema,
  mailListNodeSchema,
  mailProtectedBlockNodeSchema,
]));

function documentComplexity(document: MailTipTapDocument) {
  let count = 0;
  let maximumDepth = 0;
  const visit = (node: MailTipTapDocument | MailBlockNode | MailInlineNode | MailListItemNode, depth: number) => {
    count += 1;
    maximumDepth = Math.max(maximumDepth, depth);
    if ("content" in node) node.content.forEach((child) => visit(child, depth + 1));
  };
  visit(document, 0);
  return { count, maximumDepth };
}

export const mailTipTapDocumentSchema: z.ZodType<MailTipTapDocument> = z.object({
  type: z.literal("doc"),
  content: z.array(mailBlockNodeSchema).min(1).max(100),
}).strict().superRefine((document, context) => {
  const serializedBytes = new TextEncoder().encode(JSON.stringify(document)).byteLength;
  const complexity = documentComplexity(document);
  if (serializedBytes > 65_536) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "De e-mailinhoud is te groot.",
    });
  }
  if (complexity.count > 500 || complexity.maximumDepth > 10) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "De e-mailinhoud is te complex.",
    });
  }
});

export const mailBrandingSchema = z.object({
  clubName: z.literal("Duindorp SV"),
  logoAssetPath: z.literal("/duindorp-sv-logo.png"),
  fromName: z.string().trim().min(3).max(120).refine((value) => !/[\r\n]/u.test(value)),
  fromEmail: z.string().trim().email().max(254),
  replyToEmail: z.string().trim().email().max(254),
  contactEmail: z.string().trim().email().max(254),
  clubAddressLine: z.string().trim().min(3).max(160),
  clubPostalCode: z.string().regex(/^\d{4} [A-Z]{2}$/u),
  clubCity: z.string().trim().min(2).max(120),
  pickupName: z.string().trim().min(3).max(120),
  pickupAddressLine: z.string().trim().min(3).max(160),
  pickupPostalCode: z.string().regex(/^\d{4} [A-Z]{2}$/u),
  pickupCity: z.string().trim().min(2).max(120),
  privacyUrl: z.literal("https://duindorpsv.nl/privacy"),
  primaryColor: z.string().regex(/^#[0-9A-F]{6}$/u),
  secondaryColor: z.string().regex(/^#[0-9A-F]{6}$/u),
  accentColor: z.string().regex(/^#[0-9A-F]{6}$/u),
  footerText: z.string().trim().min(3).max(1_000).refine((value) => !/[<>]/u.test(value)),
  contrastValidated: z.boolean(),
}).strict();
export type MailBranding = z.infer<typeof mailBrandingSchema>;

export const mailLineSchema = z.object({
  memberFirstName: z.string().trim().min(1).max(160).optional(),
  product: z.string().trim().min(1).max(160),
  size: z.string().trim().min(1).max(80),
  quantity: z.number().int().min(1).max(25),
  status: z.string().trim().min(1).max(80).optional(),
}).strict();
export type MailLine = z.infer<typeof mailLineSchema>;

const protectedTableSchema = z.object({
  rows: z.array(mailLineSchema).min(1).max(250),
}).strict();

const protectedActionSchema = z.object({
  url: z.string().trim().min(9).max(2_048),
  label: z.string().trim().min(2).max(120),
}).strict();

const paymentSummaryLineSchema = z.object({
  memberFirstName: z.string().trim().min(1).max(160),
  packageName: z.string().trim().min(1).max(160),
  amountCents: z.number().int().min(0).max(10_000_000),
  currency: z.literal("EUR"),
}).strict();

export const mailProtectedValueSchemas = {
  portal_route: protectedActionSchema,
  otp_code: z.object({ code: z.string().regex(/^\d{6}$/u) }).strict(),
  otp_validity: z.object({ minutes: z.number().int().min(1).max(30) }).strict(),
  otp_warning: z.object({}).strict(),
  size_table: protectedTableSchema,
  size_action: protectedActionSchema,
  payment_summary: z.union([
    paymentSummaryLineSchema.omit({ memberFirstName: true }),
    z.object({
      orders: z.array(paymentSummaryLineSchema).min(1).max(10),
    }).strict(),
  ]),
  payment_action: protectedActionSchema,
  ready_items: protectedTableSchema,
  stock_items: protectedTableSchema,
  picked_up_items: protectedTableSchema,
  remaining_items: protectedTableSchema,
  full_package: protectedTableSchema,
  pickup_location: z.object({
    name: z.string().trim().min(1).max(120),
    address: z.string().trim().min(3).max(300),
  }).strict(),
  pickup_qr: z.object({
    portalUrl: z.string().trim().min(9).max(2_048),
  }).strict(),
  failure_reference: z.object({
    jobId: z.string().uuid(),
    reason: z.string().regex(/^[a-z0-9][a-z0-9._-]{1,63}$/u),
  }).strict(),
} satisfies Record<MailProtectedNodeKey, z.ZodTypeAny>;

export type MailProtectedValues = {
  [K in MailProtectedNodeKey]?: z.input<(typeof mailProtectedValueSchemas)[K]>;
};

export type MailShortcodeValues = Partial<Record<MailShortcodeKey, string | number>>;

export const mailTemplateSourceSchema = z.object({
  templateKey: mailTemplateKeySchema,
  subjectSource: z.string().trim().min(3).max(180).refine((value) => !/[\r\n<>]/u.test(value)),
  preheaderSource: z.string().trim().min(3).max(240).refine((value) => !/[\r\n<>]/u.test(value)),
  bodyTipTap: mailTipTapDocumentSchema,
  allowedShortcodes: z.array(mailShortcodeKeySchema).min(1).max(32),
  allowedProtectedNodes: z.array(mailProtectedNodeKeySchema).min(1).max(16),
  requiredProtectedNodes: z.array(mailProtectedNodeKeySchema).min(1).max(16),
}).strict();
export type MailTemplateSource = z.infer<typeof mailTemplateSourceSchema>;

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });
const contentHash = z.string().regex(/^[0-9a-f]{64}$/u);

export const mailTemplateRevisionSchema = z.object({
  id: uuid,
  revision: z.number().int().positive(),
  status: z.enum(["draft", "published"]),
  internalName: z.string().trim().min(3).max(120),
  subjectSource: z.string().trim().min(3).max(180),
  preheaderSource: z.string().trim().min(3).max(240),
  bodyTipTap: mailTipTapDocumentSchema,
  sanitizedHtmlSource: z.string().min(1).max(100_000).nullable(),
  textFallbackSource: z.string().trim().min(3).max(20_000),
  schemaVersion: z.literal(1),
  contentHash,
  createdAt: timestamp.optional(),
  updatedAt: timestamp.optional(),
  publishedAt: timestamp.nullable().optional(),
  publishedBy: uuid.nullable().optional(),
}).strict();

const mailTemplateWorkspaceItemSchema = z.object({
  key: mailTemplateKeySchema,
  internalName: z.string().trim().min(3).max(120),
  process: z.enum([
    "portal_access",
    "authentication",
    "size",
    "payment",
    "inventory",
    "fulfilment",
    "internal",
  ]),
  audience: z.enum(["external", "internal"]),
  active: z.boolean(),
  allowedShortcodes: z.array(mailShortcodeKeySchema).min(1).max(32),
  requiredShortcodes: z.array(mailShortcodeKeySchema).max(32),
  allowedProtectedNodes: z.array(mailProtectedNodeKeySchema).min(1).max(16),
  requiredProtectedNodes: z.array(mailProtectedNodeKeySchema).min(1).max(16),
  draft: mailTemplateRevisionSchema.extend({ status: z.literal("draft") }).nullable(),
  published: mailTemplateRevisionSchema.extend({ status: z.literal("published") }).nullable(),
}).strict();

export const mailBrandingRevisionSchema = mailBrandingSchema.extend({
  id: uuid,
  revision: z.number().int().positive(),
  status: z.enum(["draft", "published"]),
  contentHash,
  creationSource: z.enum(["system", "staff"]),
  publishedBy: uuid.nullable(),
  publishedAt: timestamp.nullable(),
  createdAt: timestamp,
  updatedAt: timestamp,
}).strict();

export const mailV2WorkspaceSchema = z.object({
  featureEnabled: z.boolean(),
  cutoverAt: timestamp.nullable(),
  shortcodes: z.array(z.object({
    key: mailShortcodeKeySchema,
    valueType: z.enum(["text", "email", "money", "url", "integer"]),
    description: z.string().trim().min(3).max(240),
  }).strict()).length(MAIL_SHORTCODE_KEYS.length),
  protectedNodes: z.array(z.object({
    key: mailProtectedNodeKeySchema,
    description: z.string().trim().min(3).max(240),
  }).strict()).length(MAIL_PROTECTED_NODE_KEYS.length),
  templates: z.array(mailTemplateWorkspaceItemSchema).length(MAIL_TEMPLATE_KEYS.length),
  branding: z.object({
    draft: mailBrandingRevisionSchema.extend({ status: z.literal("draft") }).nullable(),
    published: mailBrandingRevisionSchema.extend({ status: z.literal("published") }),
  }).strict(),
}).strict();
export type MailV2Workspace = z.infer<typeof mailV2WorkspaceSchema>;

const templateDraftInput = z.object({
  templateKey: mailTemplateKeySchema,
  expectedHash: contentHash.nullable(),
  internalName: z.string().trim().min(3).max(120),
  subjectSource: z.string().trim().min(3).max(180).refine((value) => !/[\r\n<>]/u.test(value)),
  preheaderSource: z.string().trim().min(3).max(240).refine((value) => !/[\r\n<>]/u.test(value)),
  bodyTipTap: mailTipTapDocumentSchema,
}).strict();

export const manageMailTemplateRequestSchema = z.discriminatedUnion("action", [
  templateDraftInput.extend({ action: z.literal("save") }).strict(),
  z.object({
    action: z.literal("publish"),
    revisionId: uuid,
    expectedHash: contentHash,
  }).strict(),
]);

export const previewMailTemplateRequestSchema = templateDraftInput.pick({
  templateKey: true,
  internalName: true,
  subjectSource: true,
  preheaderSource: true,
  bodyTipTap: true,
}).strict();

export const manageMailBrandingRequestSchema = z.discriminatedUnion("action", [
  mailBrandingSchema.omit({ contrastValidated: true }).extend({
    action: z.literal("save"),
    expectedHash: contentHash.nullable(),
  }).strict(),
  z.object({
    action: z.literal("publish"),
    revisionId: uuid,
    expectedHash: contentHash,
  }).strict(),
]);

export const mailManagementResponseSchema = z.object({
  revisionId: uuid,
  revision: z.number().int().positive(),
  status: z.enum(["draft", "published"]),
  contentHash,
  updatedAt: timestamp.optional(),
  publishedAt: timestamp.optional(),
  templateKey: mailTemplateKeySchema.optional(),
}).strict();

export const mailV2CutoverSnapshotSchema = z.object({
  enabled: z.boolean(),
  cutoverAt: timestamp.nullable(),
  catalogCount: z.number().int().nonnegative(),
  publishedCount: z.number().int().nonnegative(),
  brandingCount: z.number().int().nonnegative(),
  producerCount: z.number().int().nonnegative(),
  ready: z.boolean(),
  revision: contentHash,
  reused: z.boolean().optional(),
}).strict().superRefine((snapshot, context) => {
  if (snapshot.ready && (
    snapshot.catalogCount !== MAIL_TEMPLATE_KEYS.length
    || snapshot.publishedCount !== MAIL_TEMPLATE_KEYS.length
    || snapshot.brandingCount !== 1
    || snapshot.producerCount !== MAIL_TEMPLATE_KEYS.length
  )) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["ready"],
      message: "De mailcutover is alleen gereed met de volledige catalogus en branding.",
    });
  }
  if (snapshot.enabled && snapshot.cutoverAt === null) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["cutoverAt"],
      message: "Een actieve mailcutover vereist een immutable watermerk.",
    });
  }
});
export type MailV2CutoverSnapshot = z.infer<
  typeof mailV2CutoverSnapshotSchema
>;

const mailV2CutoverReasonSchema = z.string()
  .trim()
  .min(4)
  .max(500)
  .refine((value) => !/[\u0000-\u001f\u007f]/u.test(value));

export const manageMailV2CutoverRequestSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("activate"),
    expectedRevision: contentHash,
    reason: mailV2CutoverReasonSchema,
  }).strict(),
  z.object({
    action: z.literal("pause"),
    reason: mailV2CutoverReasonSchema,
  }).strict(),
]);

const fulfilmentProjectionLineSchema = z.object({
  product: z.string().trim().min(1).max(160),
  size: z.string().trim().min(1).max(80),
  quantity: z.number().int().min(1).max(25),
  status: z.string().trim().min(1).max(80).optional(),
}).strict();

const fulfilmentProjectionEventSchema = z.object({
  eventId: uuid,
  memberFirstName: z.string().trim().min(1).max(160),
  memberFullName: z.string().trim().min(1).max(320),
  teamName: z.string().trim().min(1).max(160),
  seasonName: z.string().trim().min(1).max(120),
  packageName: z.string().trim().min(1).max(160),
  issued: z.array(fulfilmentProjectionLineSchema).min(1).max(250),
  remaining: z.array(fulfilmentProjectionLineSchema).max(250),
  package: z.array(fulfilmentProjectionLineSchema).min(1).max(250),
}).strict();

export const fulfilmentMailProjectionGroupSchema = z.object({
  groupId: uuid,
  eligibilityRevision: contentHash,
  eventType: z.enum(["partial_pickup", "package_complete"]),
  template: mailTemplateSourceSchema.extend({
    id: uuid,
    contentHash,
  }).strict(),
  branding: mailBrandingSchema.extend({
    id: uuid,
    contentHash,
  }).strict(),
  events: z.array(fulfilmentProjectionEventSchema).min(1).max(10),
}).strict().superRefine((group, context) => {
  if (group.template.templateKey !== group.eventType) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["template", "templateKey"],
      message: "Template en uitgifte-event komen niet overeen.",
    });
  }
  const eventIds = new Set(group.events.map((event) => event.eventId));
  if (eventIds.size !== group.events.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["events"],
      message: "Uitgifte-events moeten uniek zijn.",
    });
  }
  for (const [index, event] of group.events.entries()) {
    if (group.eventType === "partial_pickup" && event.remaining.length === 0) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["events", index, "remaining"],
        message: "Een deelafhaling vereist resterende pakketregels.",
      });
    }
    if (group.eventType === "package_complete" && event.remaining.length !== 0) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["events", index, "remaining"],
        message: "Een eindbevestiging mag geen resterende pakketregels bevatten.",
      });
    }
  }
});

export const fulfilmentMailProjectionClaimSchema = z.object({
  leaseToken: uuid,
  groups: z.array(fulfilmentMailProjectionGroupSchema).max(10),
}).strict();

export const fulfilmentMailProjectionClaimEnvelopeSchema = z.object({
  leaseToken: uuid,
  groups: z.array(z.unknown()).max(10),
}).strict();

export const fulfilmentMailProjectionFinalizeSchema = z.object({
  groupId: uuid,
  jobId: uuid.nullable(),
  status: z.enum(["queued", "suppressed", "stale"]),
  eventCount: z.number().int().min(1).max(100),
  reused: z.boolean(),
}).strict().superRefine((result, context) => {
  if ((result.status === "queued") !== Boolean(result.jobId)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["jobId"],
      message: "Alleen een gequeue-de projectie heeft een mailjob.",
    });
  }
});

export type FulfilmentMailProjectionGroup = z.infer<
  typeof fulfilmentMailProjectionGroupSchema
>;

export const mailV2DomainTemplateKeySchema = mailTemplateKeySchema.exclude([
  "login_otp",
  "partial_pickup",
  "package_complete",
]);

const mailV2DomainMemberPayloadSchema = z.object({
  memberSeasonId: uuid,
  memberFirstName: z.string().trim().min(1).max(160),
  memberFullName: z.string().trim().min(1).max(320),
  teamName: z.string().trim().min(1).max(160),
  seasonName: z.string().trim().min(1).max(120),
  orderId: uuid.optional(),
  packageName: z.string().trim().min(1).max(160),
  amountCents: z.number().int().min(0).max(10_000_000).optional(),
  currency: z.literal("EUR"),
  lines: z.array(fulfilmentProjectionLineSchema).max(250),
}).strict();

const mailV2DomainFailurePayloadSchema = z.object({
  jobId: uuid,
  reason: z.string().regex(/^[a-z0-9][a-z0-9._-]{1,63}$/u),
}).strict();

const mailV2DomainProjectionEventSchema = z.object({
  eventId: uuid,
  payload: z.union([
    mailV2DomainMemberPayloadSchema,
    mailV2DomainFailurePayloadSchema,
  ]),
}).strict();

export const mailV2DomainProjectionGroupSchema = z.object({
  groupId: uuid,
  eligibilityRevision: contentHash,
  templateKey: mailV2DomainTemplateKeySchema,
  template: mailTemplateSourceSchema.extend({
    id: uuid,
    contentHash,
  }).strict(),
  branding: mailBrandingSchema.extend({
    id: uuid,
    contentHash,
  }).strict(),
  events: z.array(mailV2DomainProjectionEventSchema).min(1).max(100),
}).strict().superRefine((group, context) => {
  if (group.template.templateKey !== group.templateKey) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["template", "templateKey"],
      message: "Template en domeinevent komen niet overeen.",
    });
  }
  if (new Set(group.events.map((event) => event.eventId)).size !== group.events.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["events"],
      message: "Domeinevents moeten uniek zijn.",
    });
  }
  const internal = group.templateKey === "internal_email_failure";
  if (internal && group.events.length !== 1) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["events"],
      message: "Een interne foutmelding verwijst naar exact één mailjob.",
    });
  }
  for (const [index, event] of group.events.entries()) {
    if ("jobId" in event.payload) {
      if (!internal) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["events", index, "payload"],
          message: "Domeinevent en doelgroepcontext komen niet overeen.",
        });
      }
      continue;
    }
    if (internal) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["events", index, "payload"],
        message: "Domeinevent en doelgroepcontext komen niet overeen.",
      });
      continue;
    }
    const requiresOrder = ![
      "portal_access_invite",
      "portal_access_reminder",
    ].includes(group.templateKey);
    if (requiresOrder && !event.payload.orderId) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["events", index, "payload", "orderId"],
        message: "Dit mailproces vereist een pakketorder.",
      });
    }
    if ([
      "payment_request",
      "payment_reminder",
      "payment_received_waiting_stock",
      "available_payment_required",
    ].includes(group.templateKey) && event.payload.amountCents === undefined) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["events", index, "payload", "amountCents"],
        message: "Dit mailproces vereist een exact pakkettotaal.",
      });
    }
    if ([
      "size_fill_request",
      "size_fill_reminder",
      "size_review_request",
      "size_review_reminder",
      "size_confirmed",
      "payment_received_waiting_stock",
      "available_payment_required",
      "pickup_ready",
      "pickup_reminder",
      "out_of_stock",
      "back_in_stock",
    ].includes(group.templateKey) && event.payload.lines.length === 0) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["events", index, "payload", "lines"],
        message: "Dit mailproces vereist ten minste één pakketregel.",
      });
    }
  }
});

export const mailV2DomainProjectionClaimEnvelopeSchema = z.object({
  leaseToken: uuid,
  groups: z.array(z.unknown()).max(10),
}).strict();

export const mailV2DomainProjectionFinalizeSchema =
  fulfilmentMailProjectionFinalizeSchema;

export type MailV2DomainProjectionGroup = z.infer<
  typeof mailV2DomainProjectionGroupSchema
>;
