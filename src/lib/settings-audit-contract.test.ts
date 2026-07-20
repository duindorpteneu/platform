import { describe, expect, it } from "vitest";
import {
  auditFiltersSchema,
  createSeasonRequestSchema,
  inviteStaffRequestSchema,
  settingsWorkspaceSchema,
  staffRoleSchema,
  updateSettingsRequestSchema,
} from "@/lib/settings-audit-contract";

const id = "11111111-1111-4111-8111-111111111111";

describe("settings and audit contracts", () => {
  it("allows exactly the three canonical roles", () => {
    expect(staffRoleSchema.options).toEqual(["beheerder", "kledingcommissie", "uitgifte"]);
    expect(staffRoleSchema.safeParse("ouder").success).toBe(false);
  });

  it("keeps the club identity fixed", () => {
    const base = {
      settings: {
        clubName: "Andere club", contactEmail: null,
        clubAddressLine: null, clubPostalCode: null, clubCity: null,
        pickupAddressDiffers: false, pickupName: null, pickupAddressLine: null, pickupPostalCode: null, pickupCity: null,
        pickupLocation: null, activeSeasonId: null, mollieEnabled: false, emailEnabled: false,
      },
      seasons: [], staff: [], roles: ["beheerder", "kledingcommissie", "uitgifte"],
    };
    expect(settingsWorkspaceSchema.safeParse(base).success).toBe(false);
    expect(settingsWorkspaceSchema.safeParse({ ...base, settings: { ...base.settings, clubName: "Duindorp SV" }, extra: true }).success).toBe(false);
  });

  it("rejects duplicate season amounts and unknown fields", () => {
    const input = {
      contactEmail: "kleding@duindorpsv.nl", clubAddressLine: "Duinlaan 1", clubPostalCode: "2584 AB", clubCity: "Den Haag",
      pickupAddressDiffers: false, pickupName: "", pickupAddressLine: "", pickupPostalCode: "", pickupCity: "",
      activeSeasonId: id, seasonAmounts: [{ seasonId: id, amountCents: 12500 }, { seasonId: id, amountCents: 13000 }], mollieEnabled: false, emailEnabled: false,
    };
    expect(updateSettingsRequestSchema.safeParse(input).success).toBe(false);
    expect(updateSettingsRequestSchema.safeParse({ ...input, seasonAmounts: input.seasonAmounts.slice(0, 1), clubName: "Duindorp SV" }).success).toBe(false);
  });

  it("allows association settings before the first season and validates a different pickup address", () => {
    const base = {
      contactEmail: "kleding@duindorpsv.nl", clubAddressLine: "Duinlaan 1", clubPostalCode: "2584 AB", clubCity: "Den Haag",
      pickupAddressDiffers: false, pickupName: "", pickupAddressLine: "", pickupPostalCode: "", pickupCity: "",
      activeSeasonId: null, seasonAmounts: [], mollieEnabled: false, emailEnabled: false,
    };
    expect(updateSettingsRequestSchema.safeParse(base).success).toBe(true);
    expect(updateSettingsRequestSchema.safeParse({ ...base, clubCity: "" }).success).toBe(false);
    expect(updateSettingsRequestSchema.safeParse({ ...base, pickupAddressDiffers: true, pickupName: "Sportshop" }).success).toBe(false);
    expect(updateSettingsRequestSchema.safeParse({ ...base, pickupAddressDiffers: true, pickupName: "Sportshop", pickupAddressLine: "Markt 2", pickupPostalCode: "2511 AA", pickupCity: "Den Haag" }).success).toBe(true);
  });

  it("validates a new season and chronological dates", () => {
    expect(createSeasonRequestSchema.parse({ name: " 2027/2028 ", startsOn: "2027-07-01", endsOn: "2028-06-30", defaultAmountCents: 8_700, makeActive: true }).name).toBe("2027/2028");
    expect(createSeasonRequestSchema.safeParse({ name: "2027/2028", startsOn: "2028-07-01", endsOn: "2028-06-30", defaultAmountCents: 8_700, makeActive: true }).success).toBe(false);
  });

  it("normalizes safe staff invitations", () => {
    const parsed = inviteStaffRequestSchema.parse({ email: "  ADMIN@EXAMPLE.NL ", displayName: "  A. Beheerder ", role: "beheerder" });
    expect(parsed.email).toBe("admin@example.nl");
    expect(parsed.displayName).toBe("A. Beheerder");
  });

  it("allowlists audit filters", () => {
    expect(auditFiltersSchema.safeParse({ category: "payments", limit: "25" }).success).toBe(true);
    expect(auditFiltersSchema.safeParse({ category: "all", limit: "25" }).success).toBe(false);
    expect(auditFiltersSchema.safeParse({ action: "x'; drop table" }).success).toBe(false);
  });
});
