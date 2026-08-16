import { z } from "zod";

const optionalText = (maximum: number) => z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? undefined : value,
  z.string().trim().min(1).max(maximum).optional(),
);

const optionalEmail = z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? undefined : value,
  z.string().trim().email().max(320).optional(),
);

const optionalDate = z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? undefined : value,
  z.string().regex(/^\d{4}-\d{2}-\d{2}$/u).refine((value) => {
    const date = new Date(`${value}T00:00:00.000Z`);
    return !Number.isNaN(date.valueOf())
      && date.toISOString().slice(0, 10) === value
      && value >= "1900-01-01"
      && value <= new Date().toISOString().slice(0, 10);
  }).optional(),
);

export const manualMemberCreateRequestSchema = z.object({
  externalId: optionalText(120),
  firstName: z.string().trim().min(1).max(120),
  insertion: optionalText(80),
  lastName: z.string().trim().min(1).max(120),
  email: optionalEmail,
  dateOfBirth: optionalDate,
  gender: z.enum(["male", "female", "other", "unknown"]).default("unknown"),
  team: optionalText(120),
  clientRequestId: z.string().uuid(),
  allowPotentialDuplicate: z.boolean().default(false),
  expectedFingerprint: z.string().regex(/^[0-9a-f]{64}$/).nullable().default(null),
}).strict();

export const manualMemberPreflightSchema = z.object({
  seasonId: z.string().uuid(),
  seasonName: z.string().min(1).max(120),
  candidates: z.array(z.object({
    memberId: z.string().uuid(),
    memberName: z.string().min(1).max(320),
    team: z.string().min(1).max(120).nullable(),
    reasons: z.array(z.enum([
      "external_id",
      "name_date_of_birth",
      "name_email",
      "name_only",
    ])).min(1).max(4),
  }).strict()).max(100),
  fingerprint: z.string().regex(/^[0-9a-f]{64}$/),
}).strict();

export const manualMemberCreateResponseSchema = z.object({
  memberId: z.string().uuid(),
  memberSeasonId: z.string().uuid(),
  reused: z.boolean(),
}).strict();

export type ManualMemberCreateRequest = z.infer<typeof manualMemberCreateRequestSchema>;
export type ManualMemberPreflight = z.infer<typeof manualMemberPreflightSchema>;
