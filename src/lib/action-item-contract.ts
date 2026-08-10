import { z } from "zod";

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });

export const actionItemStatusSchema = z.enum([
  "open",
  "in_progress",
  "resolved",
  "dismissed",
]);
export const actionItemSeveritySchema = z.enum([
  "info",
  "warning",
  "critical",
]);

const seasonSchema = z.object({
  id: uuid,
  name: z.string().trim().min(1).max(120),
  status: z.enum(["open", "archived"]),
  active: z.boolean(),
}).strict();

const safeContextValueSchema = z.union([
  uuid,
  z.number().int().nonnegative().max(9_999_999_999),
  z.boolean(),
]);

export const actionItemWorkspaceSchema = z.object({
  tenantKey: z.literal("duindorp-sv"),
  activeSeason: z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
  }).strict().nullable(),
  selectedSeason: seasonSchema.omit({ active: true }),
  seasons: z.array(seasonSchema).max(100),
  statusCounts: z.object({
    open: z.number().int().nonnegative(),
    inProgress: z.number().int().nonnegative(),
    resolved: z.number().int().nonnegative(),
    dismissed: z.number().int().nonnegative(),
  }).strict(),
  ownerOptions: z.array(z.object({
    userId: uuid,
    displayName: z.string().trim().min(1).max(160),
    role: z.enum(["beheerder", "kledingcommissie"]),
  }).strict()).max(500),
  viewer: z.object({
    userId: uuid,
    role: z.enum(["beheerder", "kledingcommissie"]),
  }).strict(),
  offset: z.number().int().nonnegative(),
  limit: z.number().int().min(1).max(100),
  total: z.number().int().nonnegative(),
  items: z.array(z.object({
    id: uuid,
    type: z.string().regex(/^[a-z][a-z0-9_]{2,63}$/),
    seasonId: uuid,
    objectType: z.string().regex(/^[a-z][a-z0-9_]{1,63}$/),
    objectId: uuid,
    sourceType: z.string().regex(/^[a-z][a-z0-9_]{1,63}$/),
    sourceId: uuid.nullable(),
    episode: z.number().int().positive(),
    severity: actionItemSeveritySchema,
    status: actionItemStatusSchema,
    visibility: z.enum(["admin_only", "operations"]),
    reasonCode: z.string().regex(/^[a-z][a-z0-9._-]{2,63}$/),
    safeContext: z.record(safeContextValueSchema),
    ownerUserId: uuid.nullable(),
    ownerDisplayName: z.string().trim().min(1).max(160).nullable(),
    openedAt: timestamp,
    lastSeenAt: timestamp,
    dueAt: timestamp.nullable(),
    assignedAt: timestamp.nullable(),
    startedAt: timestamp.nullable(),
    resolvedAt: timestamp.nullable(),
    resolutionReason: z.string().trim().min(3).max(500).nullable(),
    revision: z.number().int().positive(),
    updatedAt: timestamp,
    actions: z.object({
      canAssign: z.boolean(),
      canStart: z.boolean(),
      canResolve: z.boolean(),
      canDismiss: z.boolean(),
    }).strict(),
  }).strict()).max(100),
}).strict();

export const actionItemQuerySchema = z.object({
  seasonId: uuid.nullable(),
  status: actionItemStatusSchema.nullable(),
  severity: actionItemSeveritySchema.nullable(),
  ownerUserId: uuid.nullable(),
  onlyUnassigned: z.boolean(),
  offset: z.number().int().nonnegative().max(1_000_000),
  limit: z.literal(50),
}).strict().superRefine((value, context) => {
  if (value.onlyUnassigned && value.ownerUserId) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Een eigenaarfilter kan niet met alleen niet-toegewezen worden gecombineerd.",
    });
  }
});

export const actionItemAssignRequestSchema = z.object({
  actionItemId: uuid,
  expectedRevision: z.number().int().positive(),
  ownerUserId: uuid.nullable(),
}).strict();

const actionItemCloseRequestCoreSchema = z.object({
  actionItemId: uuid,
  expectedRevision: z.number().int().positive(),
  reason: z.string().trim().min(3).max(500),
}).strict();

export const actionItemStartRequestSchema = z.object({
  actionItemId: uuid,
  expectedRevision: z.number().int().positive(),
}).strict();
export const actionItemResolveRequestSchema = actionItemCloseRequestCoreSchema;
export const actionItemDismissRequestSchema = actionItemCloseRequestCoreSchema;

export const actionItemMutationResponseSchema = z.object({
  id: uuid,
  status: actionItemStatusSchema,
  ownerUserId: uuid.nullable(),
  revision: z.number().int().positive(),
  updatedAt: timestamp,
  reused: z.boolean(),
}).strict();

export type ActionItemWorkspaceData = z.infer<typeof actionItemWorkspaceSchema>;
export type ActionItemQuery = z.infer<typeof actionItemQuerySchema>;
export type ActionItemMutationResponse = z.infer<typeof actionItemMutationResponseSchema>;

export function actionItemTarget(
  item: Pick<ActionItemWorkspaceData["items"][number], "type" | "objectType">,
) {
  if (
    item.type.startsWith("email_")
    || item.type.startsWith("mail_")
    || item.objectType.includes("email")
  ) {
    return { href: "/backoffice/emails", label: "Naar e-mailbeheer" };
  }
  if (
    item.type.includes("stock")
    || item.type.includes("receipt")
    || item.type.includes("allocation")
    || item.type === "paid_waiting_stock"
    || ["article_variant", "delivery", "receipt"].includes(item.objectType)
  ) {
    return { href: "/backoffice/leveringen", label: "Naar voorraad en leveringen" };
  }
  if (
    item.type.includes("payment")
    || item.objectType === "payment"
  ) {
    return { href: "/backoffice/betalingen", label: "Naar betalingen" };
  }
  if (
    item.type.includes("package")
    || item.objectType === "package_order"
  ) {
    return { href: "/backoffice/bestellingen", label: "Naar bestellingen" };
  }
  return { href: "/backoffice/leden", label: "Naar ledenbeheer" };
}
