import { z } from "zod";

const uuid = z.string().uuid();
const revisionHash = z.string().regex(/^[0-9a-f]{64}$/);
const nullableShortText = z.string().max(500).nullable();
const lineStatusSchema = z.enum([
  "backorder",
  "ready_for_pickup",
  "picked_up",
  "cancelled",
]);
const paymentStatusSchema = z.enum([
  "open",
  "pending",
  "paid",
  "failed",
  "canceled",
  "expired",
  "refunded",
  "duplicate_paid",
]);
const selectionStatusSchema = z.enum([
  "imported_unconfirmed",
  "confirmed",
  "conflict",
  "change_requested",
  "locked",
]);
const selectionSourceSchema = z.enum([
  "legacy",
  "import",
  "parent",
  "staff",
  "order",
]);

const availablePackageSchema = z.object({
  revisionId: uuid,
  name: z.string().min(1).max(120),
  description: z.string().max(1_000).nullable(),
  priceCents: z.number().int().nonnegative().max(10_000_000),
  currency: z.string().regex(/^[A-Z]{3}$/),
  revisionNumber: z.number().int().positive(),
  isDefault: z.boolean(),
  items: z.array(z.object({
    articleId: uuid,
    name: z.string().min(1).max(120),
    code: z.string().min(1).max(120),
    quantity: z.number().int().min(1).max(25),
  }).strict()).min(1).max(25),
}).strict();

const packageVariantSchema = z.object({
  id: uuid,
  label: z.string().min(1).max(80),
  active: z.boolean(),
}).strict();

const packageItemSchema = z.object({
  snapshotItemId: uuid,
  articleId: uuid,
  name: z.string().min(1).max(120),
  code: z.string().min(1).max(120),
  quantity: z.number().int().min(1).max(25),
  selectedVariantId: uuid.nullable(),
  selectionStatus: selectionStatusSchema.nullable(),
  selectionSource: selectionSourceSchema.nullable(),
  rawValue: z.string().min(1).max(160).nullable(),
  memberNote: nullableShortText,
  confirmedAt: z.string().datetime({ offset: true }).nullable(),
  requestedVariantId: uuid.nullable(),
  requestedRawValue: z.string().min(1).max(160).nullable(),
  requestedMemberNote: nullableShortText,
  lineStatus: lineStatusSchema.nullable(),
  hasReservation: z.boolean(),
  issued: z.boolean(),
  variants: z.array(packageVariantSchema).max(500),
}).strict();

const articleLineSchema = z.object({
  id: uuid,
  article: z.string().min(1).max(120),
  size: z.string().min(1).max(80),
  quantity: z.number().int().min(1).max(25),
  status: lineStatusSchema,
}).strict();

export const parentPackageOrderDatabaseSchema = z.object({
  id: uuid,
  amountDueCents: z.number().int().nonnegative().max(10_000_000),
  paymentStatus: paymentStatusSchema.nullable(),
  orderStatus: z.string().min(1).max(120),
  qrVersion: z.number().int().positive().nullable(),
  qrKeyVersion: z.number().int().positive().max(9999).nullable(),
  qrNonce: z.string().regex(/^[A-Za-z0-9_-]{43}$/).nullable(),
  packageRevisionId: uuid.nullable(),
  packageName: z.string().min(1).max(120).nullable(),
  packageDescription: z.string().max(1_000).nullable(),
  packagePriceCents: z.number().int().nonnegative().max(10_000_000).nullable(),
  currency: z.string().regex(/^[A-Z]{3}$/).nullable(),
  revisionLabel: z.string().min(1).max(160).nullable(),
  legacy: z.boolean(),
  canSwitchPackage: z.boolean(),
  sizesConfirmed: z.boolean(),
  revision: revisionHash,
  articleLines: z.array(articleLineSchema).max(100),
  items: z.array(packageItemSchema).max(25),
}).strict();

const parentPackageMemberDatabaseSchema = z.object({
  memberId: uuid,
  memberSeasonId: uuid,
  relationNumber: z.string().min(1).max(120).nullable(),
  firstName: z.string().min(1).max(160),
  insertion: z.string().max(80).nullable(),
  lastName: z.string().min(1).max(160),
  team: z.string().min(1).max(120).nullable(),
  dateOfBirth: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable(),
  gender: z.enum(["male", "female", "other", "unknown"]),
  seasonId: uuid,
  seasonName: z.string().min(1).max(120),
  availablePackages: z.array(availablePackageSchema).max(100),
  order: parentPackageOrderDatabaseSchema.nullable(),
  revision: revisionHash,
}).strict();

export const parentPackageWorkspaceDatabaseSchema = z.object({
  enabled: z.boolean(),
  members: z.array(parentPackageMemberDatabaseSchema).max(100),
}).strict();

const parentPackageOrderResponseSchema = parentPackageOrderDatabaseSchema
  .omit({ qrKeyVersion: true, qrNonce: true })
  .extend({
    qrDataUrl: z.string().startsWith("data:image/png;base64,").max(500_000).nullable(),
  })
  .strict();

export const parentPackageWorkspaceResponseSchema = z.object({
  enabled: z.boolean(),
  members: z.array(parentPackageMemberDatabaseSchema.extend({
    order: parentPackageOrderResponseSchema.nullable(),
  }).strict()).max(100),
}).strict();

export const parentPackageSelectionRequestSchema = z.object({
  memberSeasonId: uuid,
  packageRevisionId: uuid,
  revision: revisionHash,
  requestId: uuid,
}).strict();

const sizeSelectionSchema = z.object({
  articleId: uuid,
  kind: z.enum(["variant", "other"]),
  variantId: uuid.nullable(),
  note: z.string().trim().min(1).max(500).nullable(),
}).strict().superRefine((selection, context) => {
  if (
    selection.kind === "variant"
    && (selection.variantId === null || selection.note !== null)
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Een geldige maat heeft exact één variant en geen toelichting.",
    });
  }
  if (
    selection.kind === "other"
    && (selection.variantId !== null || selection.note === null)
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Anders vereist een toelichting en is geen variant.",
    });
  }
});

export const parentPackageSizesRequestSchema = z.object({
  memberSeasonId: uuid,
  revision: revisionHash,
  requestId: uuid,
  selections: z.array(sizeSelectionSchema).min(1).max(25),
}).strict().superRefine((request, context) => {
  const articleIds = request.selections.map((selection) => selection.articleId);
  if (new Set(articleIds).size !== articleIds.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["selections"],
      message: "Ieder pakketproduct mag maar één keer voorkomen.",
    });
  }
});

export const parentPackageSelectionResponseSchema = z.object({
  memberSeasonId: uuid,
  orderId: uuid,
  packageRevisionId: uuid,
  changed: z.boolean(),
  revision: revisionHash,
  reused: z.boolean(),
}).strict();

export const staffPackageSelectionRequestSchema = z.object({
  memberSeasonId: uuid,
  packageRevisionId: uuid,
  revision: revisionHash,
  reason: z.string().trim().min(3).max(500),
  requestId: uuid,
}).strict();

export const staffPackageSelectionResponseSchema = z.object({
  memberSeasonId: uuid,
  orderId: uuid,
  packageRevisionId: uuid,
  changed: z.boolean(),
  revision: revisionHash,
  reused: z.boolean(),
}).strict();

export const packageSizeChangeResolutionRequestSchema = z.object({
  requestId: uuid,
  decision: z.enum(["approve", "reject"]),
  approvedVariantId: uuid.nullable(),
  reason: z.string().trim().min(3).max(500),
  revision: revisionHash,
}).strict().superRefine((request, context) => {
  if (
    (request.decision === "approve" && request.approvedVariantId === null)
    || (request.decision === "reject" && request.approvedVariantId !== null)
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["approvedVariantId"],
      message: "Goedkeuren vereist een concrete maat; afwijzen niet.",
    });
  }
});

export const packageSizeChangeResolutionResponseSchema = z.object({
  requestId: uuid,
  memberSeasonId: uuid,
  orderLineId: uuid,
  replacedOrderLineId: uuid.optional(),
  status: z.enum(["approved", "rejected"]),
  releasedReservationId: uuid.nullable(),
  revision: revisionHash,
  reused: z.boolean(),
}).strict();

export const parentPackageSizesResponseSchema = z.object({
  memberSeasonId: uuid,
  orderId: uuid,
  confirmationId: uuid,
  selectedCount: z.number().int().min(1).max(25),
  conflictCount: z.number().int().min(0).max(25),
  changeRequestCount: z.number().int().min(0).max(25),
  sizesConfirmed: z.boolean(),
  revision: revisionHash,
  reused: z.boolean(),
}).strict();

export type ParentPackageWorkspace = z.infer<
  typeof parentPackageWorkspaceResponseSchema
>;
export type ParentPackageWorkspaceDatabase = z.infer<
  typeof parentPackageWorkspaceDatabaseSchema
>;
export type ParentPackageMember = ParentPackageWorkspace["members"][number];
export type ParentPackageSizeSelection = z.infer<typeof sizeSelectionSchema>;
