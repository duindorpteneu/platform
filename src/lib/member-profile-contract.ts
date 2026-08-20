import { z } from "zod";
import { memberDetailResponseSchema, memberGenderSchema } from "@/lib/member-overview-contract";

const optionalText = (maximum: number) => z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? null : value,
  z.string().trim().min(1).max(maximum).nullable(),
);

const optionalEmail = z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? null : value,
  z.string().trim().email().max(320).nullable(),
);

const optionalDate = z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? null : value,
  z.string().regex(/^\d{4}-\d{2}-\d{2}$/u).refine((value) => {
    const date = new Date(`${value}T00:00:00.000Z`);
    return !Number.isNaN(date.valueOf())
      && date.toISOString().slice(0, 10) === value
      && value >= "1900-01-01"
      && value <= new Date().toISOString().slice(0, 10);
  }).nullable(),
);

export const memberProfileUpdateRequestSchema = z.object({
  memberId: z.string().uuid(),
  memberSeasonId: z.string().uuid(),
  firstName: z.string().trim().min(1).max(120),
  insertion: optionalText(80),
  lastName: z.string().trim().min(1).max(120),
  email: optionalEmail,
  dateOfBirth: optionalDate,
  gender: memberGenderSchema,
  team: optionalText(120),
  revision: z.string().regex(/^[0-9a-f]{64}$/u),
  familyRevision: z.string().regex(/^[0-9a-f]{64}$/u).nullable().optional(),
  reason: z.string().trim().min(3).max(500),
  requestId: z.string().uuid(),
}).strict();

const familyEmailTransferResultSchema = z.object({
  portalAccessActive: z.boolean(),
  accessTransferred: z.boolean(),
  affectedMemberCount: z.number().int().positive(),
  affectedMemberSeasonCount: z.number().int().positive(),
  targetAccountReused: z.boolean(),
  sessionsRevoked: z.number().int().nonnegative(),
  otpChallengesInvalidated: z.number().int().nonnegative(),
  oldAuthorizedMemberSeasonCount: z.number().int().nonnegative(),
  activationMailQueued: z.boolean(),
}).strict();

export const memberProfileUpdateResponseSchema = memberDetailResponseSchema.extend({
  reused: z.boolean(),
  familyEmailTransfer: familyEmailTransferResultSchema,
}).strict();

export const memberFamilyEmailPreflightRequestSchema = z.object({
  memberId: z.string().uuid(),
  memberSeasonId: z.string().uuid(),
  email: z.string().trim().email().max(320),
  revision: z.string().regex(/^[0-9a-f]{64}$/u),
}).strict();

export const memberFamilyEmailPreflightResponseSchema = z.object({
  portalAccessActive: z.boolean(),
  transferRequired: z.boolean(),
  currentMemberEmail: z.string().min(1).max(320).nullable(),
  currentPortalEmail: z.string().email().max(320).nullable(),
  newEmail: z.string().email().max(320),
  affectedMemberCount: z.number().int().positive(),
  affectedMemberSeasonCount: z.number().int().nonnegative(),
  activePortalCount: z.number().int().nonnegative(),
  targetAccountReused: z.boolean(),
  blockedCount: z.number().int().nonnegative(),
  affectedChildren: z.array(z.object({
    memberId: z.string().uuid(),
    memberSeasonId: z.string().uuid(),
    memberName: z.string().min(1).max(320),
    team: z.string().min(1).max(120),
  }).strict()).min(1).max(500),
  familyRevision: z.string().regex(/^[0-9a-f]{64}$/u),
}).strict();

export type MemberProfileUpdateRequest = z.infer<typeof memberProfileUpdateRequestSchema>;
export type MemberFamilyEmailPreflight = z.infer<typeof memberFamilyEmailPreflightResponseSchema>;
