import { z } from "zod";

const nonNegativeInteger = z.number().int().nonnegative();
const activeSeasonSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(120),
}).strict();

export const staffShellContextSchema = z.object({
  activeSeason: activeSeasonSchema.nullable(),
}).strict();

export const dashboardOrderStatusSchema = z.enum([
  "Nog niet betaald",
  "Nalevering",
  "Gedeeltelijk af te halen",
  "Volledig af te halen",
  "Gedeeltelijk afgehaald",
  "Afgerond",
]);

export const dashboardOverviewSchema = z.object({
  activeSeason: activeSeasonSchema.nullable(),
  generatedAt: z.string().datetime({ offset: true }),
  metrics: z.object({
    totalMembers: nonNegativeInteger,
    totalOrders: nonNegativeInteger,
    paidOrders: nonNegativeInteger,
    unpaidOrders: nonNegativeInteger,
    partiallyReadyOrders: nonNegativeInteger,
    fullyReadyOrders: nonNegativeInteger,
    backorderOrders: nonNegativeInteger,
    readyOrders: nonNegativeInteger,
  }).strict(),
  recentMembers: z.array(z.object({
    orderId: z.string().uuid(),
    memberName: z.string().min(1).max(300),
    team: z.string().min(1).max(160),
    relationNumber: z.string().min(1).max(120).nullable(),
    paymentStatus: z.enum(["Betaald", "Nog te betalen"]),
    orderStatus: dashboardOrderStatusSchema,
    progressQuantity: nonNegativeInteger,
    totalQuantity: nonNegativeInteger,
    updatedAt: z.string().datetime({ offset: true }),
  }).strict()).max(5),
  activities: z.array(z.object({
    id: nonNegativeInteger,
    action: z.string().min(1).max(160),
    entityType: z.string().min(1).max(160),
    createdAt: z.string().datetime({ offset: true }),
  }).strict()).max(5),
}).strict();

export type DashboardOverview = z.infer<typeof dashboardOverviewSchema>;
export type DashboardOrderStatus = z.infer<typeof dashboardOrderStatusSchema>;
export type MetricTone = "blue" | "green" | "amber" | "slate";
export type DashboardMetric = { label: string; value: string; detail: string; tone: MetricTone };
