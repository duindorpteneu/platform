import {
  getStaffLandingPath,
  hasAal2,
  STAFF_ROLES,
  staffContextSchema,
  type StaffContext,
  type StaffRole,
} from "@/lib/staff-auth-contract";
import { cookies } from "next/headers";
import { fetchStaffContext, STAFF_SESSION_COOKIE } from "@/server/auth/staff-context";

export { getStaffLandingPath, hasAal2, STAFF_ROLES, staffContextSchema };
export type { StaffContext, StaffRole };

export async function getStaffContext(): Promise<StaffContext | null> {
  const token = (await cookies()).get(STAFF_SESSION_COOKIE)?.value;
  return token ? fetchStaffContext(token) : null;
}

export async function requireStaffRole(allowedRoles?: readonly StaffRole[]) {
  const context = await getStaffContext();
  if (!context || (allowedRoles && !allowedRoles.includes(context.role))) {
    throw new Error("STAFF_AUTHORIZATION_REQUIRED");
  }
  return context;
}
