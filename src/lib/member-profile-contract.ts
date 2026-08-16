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
  reason: z.string().trim().min(3).max(500),
  requestId: z.string().uuid(),
}).strict();

export const memberProfileUpdateResponseSchema = memberDetailResponseSchema.extend({
  reused: z.boolean(),
}).strict();

export type MemberProfileUpdateRequest = z.infer<typeof memberProfileUpdateRequestSchema>;
