import { z } from "zod";
import { dashboardOrderStatusSchema } from "@/lib/dashboard-contract";

const activeSeasonSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(120),
}).strict();
const nonNegativeInteger = z.number().int().nonnegative();
const paymentStatusSchema = z.enum([
  "Betaald",
  "Nog te betalen",
  "Controle vereist",
]);
export const memberLineStatusSchema = z.enum(["backorder", "ready_for_pickup", "picked_up", "cancelled"]);
export const memberGenderSchema = z.enum(["male", "female", "other", "unknown"]);
const uuid = z.string().uuid();

export const memberSizeProfileSchema = z.object({
  seasonId: uuid,
  seasonName: z.string().min(1).max(120),
  editable: z.boolean(),
  revision: z.string().regex(/^[0-9a-f]{64}$/),
  articles: z.array(z.object({
    id: uuid,
    name: z.string().min(1).max(120),
    code: z.string().min(2).max(24),
    active: z.boolean(),
    selectedVariantId: uuid.nullable(),
    ordered: z.boolean(),
    orderLineStatus: memberLineStatusSchema.nullable(),
    variants: z.array(z.object({
      id: uuid,
      size: z.string().min(1).max(80),
      active: z.boolean(),
    }).strict()).max(500),
  }).strict()).max(500),
}).strict().superRefine((profile, context) => {
  profile.articles.forEach((article, index) => {
    if (article.selectedVariantId && !article.variants.some((variant) => variant.id === article.selectedVariantId)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["articles", index, "selectedVariantId"], message: "De geselecteerde maat ontbreekt." });
    }
    if (article.ordered !== Boolean(article.orderLineStatus)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["articles", index, "ordered"], message: "Bestelstatus en orderregel komen niet overeen." });
    }
  });
});

const optionalTrimmedString = (maximum: number) => z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? undefined : value,
  z.string().trim().min(1).max(maximum).optional(),
);
const optionalSelection = <T extends z.ZodTypeAny>(schema: T) => z.preprocess(
  (value) => value === "" ? undefined : value,
  schema.optional(),
);

export const memberListQuerySchema = z.object({
  search: optionalTrimmedString(120),
  team: optionalTrimmedString(120),
  payment: optionalSelection(z.enum([
    "paid",
    "unpaid",
    "review",
    "no_order",
  ])),
  orderStatus: optionalSelection(dashboardOrderStatusSchema),
  articleId: optionalSelection(z.string().uuid()),
  size: optionalTrimmedString(80),
  lineStatus: optionalSelection(memberLineStatusSchema),
  member: optionalSelection(z.string().uuid()),
  page: z.coerce.number().int().min(1).max(2001).default(1),
}).strict();

export const memberSavedViewFiltersSchema = z.object({
  team: z.string().trim().min(1).max(120).optional(),
  payment: z.enum(["paid", "unpaid", "review", "no_order"]).optional(),
  orderStatus: dashboardOrderStatusSchema.optional(),
  articleId: uuid.optional(),
  size: z.string().trim().min(1).max(80).optional(),
  lineStatus: memberLineStatusSchema.optional(),
}).strict();

export function memberSavedViewFiltersFromQuery(
  query: MemberListQuery,
): z.infer<typeof memberSavedViewFiltersSchema> {
  return memberSavedViewFiltersSchema.parse({
    team: query.team,
    payment: query.payment,
    orderStatus: query.orderStatus,
    articleId: query.articleId,
    size: query.size,
    lineStatus: query.lineStatus,
  });
}

export const memberSavedViewSchema = z.object({
  id: uuid,
  scope: z.literal("members"),
  seasonId: uuid,
  name: z.string().trim().min(1).max(80),
  schemaVersion: z.literal(1),
  filters: memberSavedViewFiltersSchema,
  valid: z.boolean(),
  invalidReason: z.enum([
    "filters_stale",
    "schema_version_unsupported",
  ]).nullable(),
  updatedAt: z.string().datetime({ offset: true }),
}).strict().superRefine((view, context) => {
  if (view.valid !== (view.invalidReason === null)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["invalidReason"],
      message: "Een opgeslagen weergave heeft een inconsistente geldigheid.",
    });
  }
});

export const memberSavedViewsResponseSchema = z.object({
  scope: z.literal("members"),
  seasonId: uuid,
  views: z.array(memberSavedViewSchema).max(100),
}).strict();

export const saveMemberSavedViewRequestSchema = z.object({
  viewId: uuid.nullable(),
  seasonId: uuid,
  name: z.string().trim().min(1).max(80),
  schemaVersion: z.literal(1),
  filters: memberSavedViewFiltersSchema,
}).strict();

export const deleteMemberSavedViewRequestSchema = z.object({
  viewId: uuid,
  seasonId: uuid,
}).strict();

export const deleteMemberSavedViewResponseSchema = z.object({
  id: uuid,
  seasonId: uuid,
  deleted: z.literal(true),
}).strict();

export const applyMemberSavedViewRequestSchema = z.object({
  viewId: uuid,
  seasonId: uuid,
}).strict();

export const applyMemberSavedViewResponseSchema = z.object({
  id: uuid,
  seasonId: uuid,
  schemaVersion: z.literal(1),
  filters: memberSavedViewFiltersSchema,
}).strict();

const memberOrderSummarySchema = z.object({
  id: z.string().uuid(),
  amountDueCents: nonNegativeInteger,
  paymentStatus: paymentStatusSchema,
  orderStatus: dashboardOrderStatusSchema,
  progressQuantity: nonNegativeInteger,
  totalQuantity: nonNegativeInteger,
}).strict();

export const memberListResponseSchema = z.object({
  activeSeason: activeSeasonSchema.nullable(),
  totalCount: nonNegativeInteger,
  activeCount: nonNegativeInteger,
  filteredCount: nonNegativeInteger,
  filterOptions: z.object({
    teams: z.array(z.string().min(1).max(120)).max(500),
    articles: z.array(z.object({ id: z.string().uuid(), name: z.string().min(1).max(160) }).strict()).max(500),
    sizes: z.array(z.string().min(1).max(80)).max(500),
  }).strict(),
  members: z.array(z.object({
    id: z.string().uuid(),
    memberSeasonId: uuid.nullable(),
    memberName: z.string().min(1).max(320),
    relationNumber: z.string().min(1).max(120).nullable(),
    team: z.string().min(1).max(120),
    activeForSeason: z.boolean(),
    updatedAt: z.string().datetime({ offset: true }),
    order: memberOrderSummarySchema.nullable(),
    bulkEligibility: z.object({
      portalAccessPreflight: z.boolean(),
      mailPreflight: z.boolean(),
      teamStatusPreflight: z.boolean(),
    }).strict(),
  }).strict()).max(50),
}).strict();

export const memberDetailResponseSchema = z.object({
  id: z.string().uuid(),
  memberName: z.string().min(1).max(320),
  firstName: z.string().min(1).max(120),
  insertion: z.string().max(80).nullable(),
  lastName: z.string().min(1).max(120),
  relationNumber: z.string().min(1).max(120).nullable(),
  email: z.string().min(1).max(320).nullable(),
  team: z.string().min(1).max(120),
  activeForSeason: z.boolean(),
  gender: memberGenderSchema,
  dateOfBirth: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable(),
  updatedAt: z.string().datetime({ offset: true }),
  activeSeason: activeSeasonSchema.nullable(),
  memberSeasons: z.array(z.object({
    id: uuid,
    seasonId: uuid,
    seasonName: z.string().min(1).max(120),
    team: z.string().min(1).max(120).nullable(),
    participationStatus: z.enum(["active", "inactive", "unknown"]),
    reconciliationStatus: z.enum(["resolved", "legacy_unknown"]),
  }).strict()).max(100),
  sizeProfile: memberSizeProfileSchema.nullable(),
  parentLinks: z.array(z.object({
    id: z.string().uuid(),
    email: z.string().email().max(320),
    linkedAt: z.string().datetime({ offset: true }),
  }).strict()).max(50),
  order: z.object({
    id: z.string().uuid(),
    amountDueCents: nonNegativeInteger,
    orderStatus: dashboardOrderStatusSchema,
    paymentStatus: paymentStatusSchema,
    paidAt: z.string().datetime({ offset: true }).nullable(),
    qrStatus: z.enum(["Actief", "Ingetrokken", "Niet aangemaakt"]),
    lines: z.array(z.object({
      id: z.string().uuid(),
      article: z.string().min(1).max(160),
      size: z.string().min(1).max(80),
      quantity: z.number().int().positive(),
      status: memberLineStatusSchema,
      lineKind: z.enum(["package", "loose"]),
      canRemove: z.boolean(),
    }).strict()).max(100),
  }).strict().nullable(),
  activities: z.array(z.object({
    id: nonNegativeInteger,
    action: z.string().min(1).max(160),
    entityType: z.string().min(1).max(160),
    createdAt: z.string().datetime({ offset: true }),
  }).strict()).max(10),
}).strict();

export const memberStatusRequestSchema = z.object({
  memberId: z.string().uuid(),
  active: z.boolean(),
  reason: z.string().trim().min(3).max(240),
}).strict();

export const memberStatusResponseSchema = z.object({
  memberId: z.string().uuid(),
  memberSeasonId: z.string().uuid(),
  seasonId: z.string().uuid(),
  activeForSeason: z.boolean(),
}).strict();

export const memberSizesRequestSchema = z.object({
  memberId: uuid,
  seasonId: uuid,
  revision: z.string().regex(/^[0-9a-f]{64}$/),
  sizes: z.array(z.object({
    articleId: uuid,
    variantId: uuid.nullable(),
  }).strict()).max(25),
}).strict().superRefine((value, context) => {
  if (new Set(value.sizes.map((size) => size.articleId)).size !== value.sizes.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["sizes"], message: "Een artikel mag maar één maat hebben." });
  }
});

export const teamMemberStatusRequestSchema = z.object({
  team: z.string().trim().min(1).max(120),
  active: z.boolean(),
  reason: z.string().trim().max(240).optional(),
  previewToken: z.string().min(64).max(4_000).optional(),
  commit: z.boolean(),
}).strict().superRefine((value, context) => {
  if (value.commit && (!value.reason || value.reason.length < 3)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["reason"], message: "Een reden van minimaal drie tekens is verplicht." });
  }
  if (value.commit && !value.previewToken) context.addIssue({ code: z.ZodIssueCode.custom, path: ["previewToken"], message: "Controleer de wijzigingen opnieuw." });
  if (!value.commit && value.previewToken) context.addIssue({ code: z.ZodIssueCode.custom, path: ["previewToken"], message: "Een previewtoken hoort niet bij een previewaanvraag." });
});

export const teamMemberStatusResponseSchema = z.object({
  seasonId: z.string().uuid(),
  team: z.string().min(1).max(120),
  totalMembers: nonNegativeInteger,
  changedMembers: nonNegativeInteger,
  unchangedMembers: nonNegativeInteger,
  activeForSeason: z.boolean(),
  committed: z.boolean(),
  previewToken: z.string().min(64).max(4_000).optional(),
}).strict();

export type MemberListQuery = z.infer<typeof memberListQuerySchema>;
export type MemberListResponse = z.infer<typeof memberListResponseSchema>;
export type MemberSavedViewFilters = z.infer<typeof memberSavedViewFiltersSchema>;
export type MemberSavedView = z.infer<typeof memberSavedViewSchema>;
export type MemberSavedViewsResponse = z.infer<typeof memberSavedViewsResponseSchema>;
export type MemberDetailResponse = z.infer<typeof memberDetailResponseSchema>;
export type MemberSizeProfile = z.infer<typeof memberSizeProfileSchema>;
export type MemberLineStatus = z.infer<typeof memberLineStatusSchema>;
export type TeamMemberStatusResponse = z.infer<typeof teamMemberStatusResponseSchema>;
