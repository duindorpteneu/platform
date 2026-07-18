import { describe, expect, it } from "vitest";
import { hasStaffPermission } from "@/server/auth/role-guards";
import { getStaffLandingPath, hasAal2 } from "@/server/auth/staff";

describe("staff role permissions", () => {
  it("keeps issuance deliberately narrow", () => {
    expect(hasStaffPermission("uitgifte", "fulfilment:read")).toBe(true);
    expect(hasStaffPermission("uitgifte", "payments")).toBe(false);
    expect(hasStaffPermission("uitgifte", "exports")).toBe(false);
  });

  it("allows operational members to manage the catalog but not staff settings", () => {
    expect(hasStaffPermission("kledingcommissie", "catalog")).toBe(true);
    expect(hasStaffPermission("kledingcommissie", "settings")).toBe(false);
  });

  it("requires AAL2 and sends issuance staff to the scanner", () => {
    expect(hasAal2("aal1")).toBe(false);
    expect(hasAal2("aal2")).toBe(true);
    expect(getStaffLandingPath("uitgifte")).toBe("/uitgifte");
    expect(getStaffLandingPath("beheerder")).toBe("/backoffice");
  });
});
