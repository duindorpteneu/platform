import { z } from "zod";
import { dashboardOrderStatusSchema } from "@/lib/dashboard-contract";

const activeSeasonSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(120),
}).strict();
const nonNegativeInteger = z.number().int().nonnegative();
const paymentStatusSchema = z.enum(["Betaald", "Nog te betalen"]);
export const memberLineStatusSchema = z.enum(["backorder", "ready_for_pickup", "picked_up", "cancelled"]);

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
  payment: optionalSelection(z.enum(["paid", "unpaid", "no_order"])),
  orderStatus: optionalSelection(dashboardOrderStatusSchema),
  articleId: optionalSelection(z.string().uuid()),
  size: optionalTrimmedString(80),
  lineStatus: optionalSelection(memberLineStatusSchema),
  member: optionalSelection(z.string().uuid()),
  page: z.coerce.number().int().min(1).max(2001).default(1),
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
    memberName: z.string().min(1).max(320),
    relationNumber: z.string().min(1).max(80),
    team: z.string().min(1).max(120),
    activeForSeason: z.boolean(),
    updatedAt: z.string().datetime({ offset: true }),
    order: memberOrderSummarySchema.nullable(),
  }).strict()).max(50),
}).strict();

export const memberDetailResponseSchema = z.object({
  id: z.string().uuid(),
  memberName: z.string().min(1).max(320),
  firstName: z.string().min(1).max(120),
  insertion: z.string().max(80).nullable(),
  lastName: z.string().min(1).max(120),
  relationNumber: z.string().min(1).max(80),
  email: z.string().email().max(320),
  team: z.string().min(1).max(120),
  activeForSeason: z.boolean(),
  updatedAt: z.string().datetime({ offset: true }),
  activeSeason: activeSeasonSchema.nullable(),
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
  activeForSeason: z.boolean(),
}).strict();

export type MemberListQuery = z.infer<typeof memberListQuerySchema>;
export type MemberListResponse = z.infer<typeof memberListResponseSchema>;
export type MemberDetailResponse = z.infer<typeof memberDetailResponseSchema>;
export type MemberLineStatus = z.infer<typeof memberLineStatusSchema>;
