import { describe, expect, it } from "vitest";
import { hasStaffPermission } from "@/server/auth/role-guards";

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
});
