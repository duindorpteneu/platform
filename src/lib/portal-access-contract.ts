import { z } from "zod";

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: true });
const revision = z.string().regex(/^[0-9a-f]{64}$/);
const uniqueIds = z.array(uuid).min(1).max(500).superRefine((values, context) => {
  if (new Set(values).size !== values.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "De selectie bevat dubbele identifiers.",
    });
  }
});

const seasonSchema = z.object({
  id: uuid,
  name: z.string().trim().min(1).max(120),
  status: z.enum(["open", "archived"]),
  active: z.boolean(),
}).strict();

const parentGrantSchema = z.object({
  id: uuid,
  status: z.enum(["pending_account", "review_required", "active", "revoked"]),
  source: z.enum(["legacy_review", "administrator"]),
  grantedAt: timestamp.nullable(),
  revokedAt: timestamp.nullable(),
}).strict();

export const portalAccessWorkspaceSchema = z.object({
  activeSeason: z.object({
    id: uuid,
    name: z.string().trim().min(1).max(120),
  }).strict().nullable(),
  selectedSeason: seasonSchema.omit({ active: true }),
  seasons: z.array(seasonSchema).max(100),
  offset: z.number().int().nonnegative(),
  limit: z.number().int().min(1).max(100),
  total: z.number().int().nonnegative(),
  members: z.array(z.object({
    memberSeasonId: uuid,
    memberId: uuid,
    relationNumber: z.string().trim().min(1).max(120).nullable(),
    firstName: z.string().trim().min(1).max(160),
    insertion: z.string().max(80).nullable(),
    lastName: z.string().trim().min(1).max(160),
    emailState: z.enum(["valid", "missing", "invalid"]),
    emailMasked: z.string().max(254).nullable(),
    sharedEmailMemberCount: z.number().int().nonnegative().max(10_000),
    team: z.string().max(120).nullable(),
    participationStatus: z.enum(["active", "inactive", "unknown"]),
    reconciliationStatus: z.enum(["resolved", "legacy_unknown"]),
    emailValid: z.boolean(),
    grant: parentGrantSchema.nullable(),
  }).strict()).max(100),
}).strict();

export const portalAccessQuerySchema = z.object({
  seasonId: uuid.nullable(),
  search: z.string().trim().max(120).nullable(),
  offset: z.number().int().nonnegative().max(1_000_000),
  limit: z.literal(50),
}).strict();

export const portalAccessPreflightRequestSchema = z.discriminatedUnion("operation", [
  z.object({
    operation: z.literal("activate"),
    seasonId: uuid,
    memberSeasonIds: uniqueIds,
  }).strict(),
  z.object({
    operation: z.literal("revoke"),
    seasonId: uuid,
    grantIds: uniqueIds,
  }).strict(),
]);

const previewMemberSchema = z.object({
  memberSeasonId: uuid,
  memberId: uuid.nullable(),
  relationNumber: z.string().max(120).nullable(),
  firstName: z.string().max(160).nullable(),
  insertion: z.string().max(80).nullable(),
  lastName: z.string().max(160).nullable(),
  team: z.string().max(120).nullable(),
  status: z.enum(["eligible", "unchanged", "blocked"]),
  activeGrantId: uuid.nullable(),
}).strict();

const portalAccessPreviewCoreSchema = z.object({
  operation: z.enum(["activate", "revoke"]),
  seasonId: uuid,
  seasonName: z.string().trim().min(1).max(120),
  selectionCount: z.number().int().min(1).max(500),
  eligibleCount: z.number().int().min(0).max(500),
  unchangedCount: z.number().int().min(0).max(500),
  blockedCount: z.number().int().min(0).max(500),
  mailPreview: z.object({
    subject: z.string().trim().min(1).max(200),
    text: z.string().trim().min(1).max(10_000),
    templateVersion: z.number().int().positive(),
  }).strict().nullable(),
  groups: z.array(z.object({
    key: revision,
    email: z.string().email().max(254).nullable(),
    existingAccount: z.boolean(),
    invitationRequired: z.boolean(),
    nonSelectedCount: z.number().int().nonnegative().max(10_000),
    status: z.enum(["eligible", "unchanged", "blocked"]),
    blockers: z.array(z.string().regex(/^[a-z][a-z0-9_]{1,63}$/)).max(12),
    members: z.array(previewMemberSchema).min(1).max(500),
  }).strict()).min(1).max(500),
}).strict();

export const portalAccessPreviewDatabaseSchema = portalAccessPreviewCoreSchema.omit({
  mailPreview: true,
}).extend({
  revision,
  mailTemplate: z.object({
    key: z.literal("portal_access_invite"),
    version: z.number().int().positive(),
    subjectSource: z.string().trim().min(3).max(180),
    bodySource: z.string().trim().min(10).max(10_000),
    allowedShortcodes: z.array(
      z.string().regex(/^{{[a-z_]+}}$/),
    ).min(1).max(32),
    clubName: z.string().trim().min(1).max(160),
    contactEmail: z.string().email().max(320).nullable(),
  }).strict().nullable(),
}).strict();

export const portalAccessPreviewResponseSchema = portalAccessPreviewCoreSchema.extend({
  previewToken: z.string().min(64).max(4_096),
}).strict();

export const portalAccessActivateRequestSchema = z.object({
  seasonId: uuid,
  memberSeasonIds: uniqueIds,
  previewToken: z.string().min(64).max(4_096),
  batchKey: uuid,
}).strict();

export const portalAccessRevokeRequestSchema = z.object({
  seasonId: uuid,
  grantIds: uniqueIds,
  reason: z.string().trim().min(3).max(500),
  previewToken: z.string().min(64).max(4_096),
  batchKey: uuid,
}).strict();

export const portalAccessCommitResponseSchema = z.object({
  operation: z.enum(["activate", "revoke"]),
  seasonId: uuid,
  selectedCount: z.number().int().min(1).max(500),
  changedCount: z.number().int().min(0).max(500),
  unchangedCount: z.number().int().min(0).max(500),
  groupCount: z.number().int().min(1).max(500),
  inviteJobCount: z.number().int().min(0).max(500),
  sessionsRevoked: z.number().int().nonnegative(),
  committed: z.literal(true),
  reused: z.boolean(),
}).strict();

export type PortalAccessWorkspaceData = z.infer<typeof portalAccessWorkspaceSchema>;
export type PortalAccessPreflightRequest = z.infer<typeof portalAccessPreflightRequestSchema>;
export type PortalAccessPreviewResponse = z.infer<typeof portalAccessPreviewResponseSchema>;
export type PortalAccessCommitResponse = z.infer<typeof portalAccessCommitResponseSchema>;
