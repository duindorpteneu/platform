import type { StaffRole } from "@/server/auth/staff";

export const ROLE_PERMISSIONS = {
  beheerder: ["dashboard", "members:read", "members:write", "imports", "catalog", "orders", "payments", "stock", "fulfilment", "emails", "exports", "settings", "audit"],
  kledingcommissie: ["dashboard", "members:read", "members:write", "imports", "catalog", "orders", "payments", "stock", "fulfilment", "emails", "exports", "audit:operations"],
  uitgifte: ["fulfilment:read", "fulfilment:write"],
} as const satisfies Record<StaffRole, readonly string[]>;

export type StaffPermission = (typeof ROLE_PERMISSIONS)[StaffRole][number];

export function hasStaffPermission(role: StaffRole, permission: StaffPermission) {
  return ROLE_PERMISSIONS[role].includes(permission as never);
}
