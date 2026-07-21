import { z } from "zod";

export const STAFF_ROLES = ["beheerder", "kledingcommissie", "uitgifte"] as const;
export type StaffRole = (typeof STAFF_ROLES)[number];

export const staffContextSchema = z.object({
  userId: z.string().uuid(),
  displayName: z.string().min(1).max(200),
  role: z.enum(STAFF_ROLES),
  activeSeason: z.object({
    id: z.string().uuid(),
    name: z.string().min(1).max(120),
  }).strict().nullable(),
}).strict();

export type StaffContext = z.infer<typeof staffContextSchema>;

export function hasAal2(level: string | null | undefined) {
  return level === "aal2";
}

export function getStaffLandingPath(role: StaffRole) {
  return role === "uitgifte" ? "/uitgifte" : "/backoffice";
}
