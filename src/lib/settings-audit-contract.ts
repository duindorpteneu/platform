import { z } from "zod";

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });
const nullableTimestamp = timestamp.nullable();
const nullableUuid = uuid.nullable();

export const staffRoleSchema = z.enum(["beheerder", "kledingcommissie", "uitgifte"]);
export const seasonStatusSchema = z.enum(["open", "archived"]);
export const auditCategorySchema = z.enum([
  "members", "orders", "payments", "inventory", "fulfilment",
  "communications", "settings", "security",
]);

const settingsSchema = z.object({
  clubName: z.literal("Duindorp SV"),
  contactEmail: z.string().email().max(254).nullable(),
  clubAddressLine: z.string().min(1).max(160).nullable(),
  clubPostalCode: z.string().regex(/^[0-9]{4} [A-Z]{2}$/).nullable(),
  clubCity: z.string().min(1).max(120).nullable(),
  pickupAddressDiffers: z.boolean(),
  pickupName: z.string().min(1).max(120).nullable(),
  pickupAddressLine: z.string().min(1).max(160).nullable(),
  pickupPostalCode: z.string().regex(/^[0-9]{4} [A-Z]{2}$/).nullable(),
  pickupCity: z.string().min(1).max(120).nullable(),
  pickupLocation: z.string().min(1).max(240).nullable(),
  brandingRevisionId: uuid,
  brandingRevision: z.number().int().positive(),
  brandingContentHash: z.string().regex(/^[a-f0-9]{64}$/),
  activeSeasonId: nullableUuid,
  mollieEnabled: z.boolean(),
  emailEnabled: z.boolean(),
}).strict();

const seasonSchema = z.object({
  id: uuid,
  name: z.string().min(1).max(120),
  status: seasonStatusSchema,
  startsOn: z.string().date().nullable(),
  endsOn: z.string().date().nullable(),
  defaultAmountCents: z.number().int().min(0).max(10_000_000),
  active: z.boolean(),
}).strict();

const staffProfileSchema = z.object({
  authUserId: uuid,
  displayName: z.string().min(2).max(100),
  role: staffRoleSchema,
  active: z.boolean(),
  lastLoginAt: nullableTimestamp,
  createdAt: timestamp,
  isCurrentUser: z.boolean(),
}).strict();

export const settingsWorkspaceSchema = z.object({
  settings: settingsSchema,
  seasons: z.array(seasonSchema).max(50),
  staff: z.array(staffProfileSchema).max(250),
  roles: z.array(staffRoleSchema).length(3),
}).strict().superRefine((workspace, context) => {
  if (new Set(workspace.roles).size !== 3) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["roles"], message: "De drie rollen moeten uniek zijn." });
  }
  if (workspace.settings.activeSeasonId && !workspace.seasons.some((season) => season.id === workspace.settings.activeSeasonId && season.active)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["settings", "activeSeasonId"], message: "Het actieve seizoen ontbreekt." });
  }
});

export const updateSettingsRequestSchema = z.object({
  activeSeasonId: nullableUuid,
  seasonAmounts: z.array(z.object({
    seasonId: uuid,
    amountCents: z.number().int().min(0).max(10_000_000),
  }).strict()).max(50).refine((items) => new Set(items.map((item) => item.seasonId)).size === items.length, "Seizoenen moeten uniek zijn."),
  mollieEnabled: z.boolean(),
  emailEnabled: z.boolean(),
}).strict();

const optionalDate = z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? null : value,
  z.string().date().nullable(),
);

export const createSeasonRequestSchema = z.object({
  name: z.string().trim().min(1).max(120),
  startsOn: optionalDate,
  endsOn: optionalDate,
  defaultAmountCents: z.number().int().min(0).max(10_000_000),
  makeActive: z.boolean(),
}).strict().superRefine((value, context) => {
  if (value.startsOn && value.endsOn && value.startsOn > value.endsOn) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["endsOn"], message: "De einddatum moet na de startdatum liggen." });
  }
});

export const updateStaffRequestSchema = z.object({
  authUserId: uuid,
  displayName: z.string().trim().min(2).max(100),
  role: staffRoleSchema,
  active: z.boolean(),
}).strict();

export const inviteStaffRequestSchema = z.object({
  email: z.string().trim().toLowerCase().email().max(254),
  displayName: z.string().trim().min(2).max(100),
  role: staffRoleSchema,
}).strict();

export const staffMutationResponseSchema = z.object({
  authUserId: uuid,
  displayName: z.string().min(2).max(100),
  role: staffRoleSchema,
  active: z.boolean(),
}).strict();

type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };
const auditMetadataValueSchema: z.ZodType<JsonValue> = z.lazy(() => z.union([
  z.string(), z.number(), z.boolean(), z.null(),
  z.array(auditMetadataValueSchema).max(250),
  z.record(z.string(), auditMetadataValueSchema),
]));

const auditRowSchema = z.object({
  id: z.string().regex(/^\d+$/),
  action: z.string().min(3).max(100),
  category: auditCategorySchema,
  entityType: z.string().min(1).max(100),
  entityId: nullableUuid,
  metadata: z.record(z.string(), auditMetadataValueSchema),
  correlationId: nullableUuid,
  createdAt: timestamp,
  actorUserId: nullableUuid,
  actorName: z.string().min(1).max(100),
}).strict();

export const auditWorkspaceSchema = z.object({
  viewerRole: z.enum(["beheerder", "kledingcommissie"]),
  categories: z.array(auditCategorySchema).min(6).max(8),
  actors: z.array(z.object({ id: uuid, displayName: z.string().min(2).max(100) }).strict()).max(250),
  rows: z.array(auditRowSchema).max(100),
  limit: z.number().int().min(1).max(100),
}).strict();

export const auditFiltersSchema = z.object({
  category: auditCategorySchema.optional(),
  action: z.string().regex(/^[a-z][a-z0-9_.-]+$/).max(100).optional(),
  actorUserId: uuid.optional(),
  before: timestamp.optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
}).strict();

export type SettingsWorkspace = z.infer<typeof settingsWorkspaceSchema>;
export type UpdateSettingsRequest = z.infer<typeof updateSettingsRequestSchema>;
export type CreateSeasonRequest = z.infer<typeof createSeasonRequestSchema>;
export type AuditWorkspace = z.infer<typeof auditWorkspaceSchema>;
export type AuditFilters = z.infer<typeof auditFiltersSchema>;
export type StaffRole = z.infer<typeof staffRoleSchema>;
