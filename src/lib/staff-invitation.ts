import { z } from "zod";

const token = z.string().min(10).max(4_096).regex(/^[A-Za-z0-9._-]+$/);
const passwordFragmentSchema = z.object({
  type: z.enum(["invite", "recovery"]),
  access_token: token,
  refresh_token: token,
}).passthrough();

function parseStaffPasswordFragment(fragment: string, expectedType: "invite" | "recovery") {
  const parameters = Object.fromEntries(new URLSearchParams(fragment.startsWith("#") ? fragment.slice(1) : fragment));
  const parsed = passwordFragmentSchema.safeParse(parameters);
  if (!parsed.success || parsed.data.type !== expectedType) return null;
  return { accessToken: parsed.data.access_token, refreshToken: parsed.data.refresh_token };
}

export function parseStaffInvitationFragment(fragment: string) {
  return parseStaffPasswordFragment(fragment, "invite");
}

export function parseStaffRecoveryFragment(fragment: string) {
  return parseStaffPasswordFragment(fragment, "recovery");
}

export function resolveStaffRecoveryRedirect(pathname: string, fragment: string) {
  if (pathname === "/staff/reset-password" || !parseStaffRecoveryFragment(fragment)) return null;
  const normalizedFragment = fragment.startsWith("#") ? fragment : `#${fragment}`;
  return `/staff/reset-password${normalizedFragment}`;
}
