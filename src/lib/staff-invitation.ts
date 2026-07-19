import { z } from "zod";

const token = z.string().min(10).max(4_096).regex(/^[A-Za-z0-9._-]+$/);
const inviteFragmentSchema = z.object({
  type: z.literal("invite"),
  access_token: token,
  refresh_token: token,
}).passthrough();

export function parseStaffInvitationFragment(fragment: string) {
  const parameters = Object.fromEntries(new URLSearchParams(fragment.startsWith("#") ? fragment.slice(1) : fragment));
  const parsed = inviteFragmentSchema.safeParse(parameters);
  if (!parsed.success) return null;
  return { accessToken: parsed.data.access_token, refreshToken: parsed.data.refresh_token };
}
