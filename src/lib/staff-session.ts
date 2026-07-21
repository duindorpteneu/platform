import { z } from "zod";

const staffSessionSchema = z.object({
  landingPath: z.enum(["/backoffice", "/uitgifte"]),
}).strict();

async function parseLandingPath(response: Response) {
  if (!response.ok) return null;
  try {
    const parsed = staffSessionSchema.safeParse(await response.json());
    return parsed.success ? parsed.data.landingPath : null;
  } catch {
    return null;
  }
}

export async function resolveStaffLandingPath() {
  let response: Response;
  try {
    response = await fetch("/api/staff-auth/session", {
      cache: "no-store",
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
  } catch {
    return null;
  }
  return parseLandingPath(response);
}

export async function synchronizeStaffSession(exchangeToken: string) {
  let response: Response;
  try {
    response = await fetch("/api/staff-auth/session", {
      method: "POST",
      cache: "no-store",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-Duindorp-CSRF": "same-origin",
      },
      body: JSON.stringify({ exchangeToken }),
    });
  } catch {
    return null;
  }
  return parseLandingPath(response);
}

export async function resolveStaffLandingPathWithRetry(options: { attempts?: number; delayMs?: number } = {}) {
  const attempts = Math.max(1, options.attempts ?? 4);
  const delayMs = Math.max(0, options.delayMs ?? 200);

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const landingPath = await resolveStaffLandingPath();
    if (landingPath) return landingPath;
    if (attempt < attempts && delayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return null;
}
