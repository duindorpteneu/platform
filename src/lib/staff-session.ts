import { z } from "zod";

const staffSessionSchema = z.object({
  landingPath: z.enum(["/backoffice", "/uitgifte"]),
}).strict();

export async function resolveStaffLandingPath() {
  const response = await fetch("/api/staff-auth/session", {
    cache: "no-store",
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  });
  if (!response.ok) return null;

  const parsed = staffSessionSchema.safeParse(await response.json());
  return parsed.success ? parsed.data.landingPath : null;
}
