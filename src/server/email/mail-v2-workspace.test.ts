import { describe, expect, it } from "vitest";
import {
  contrastRatio,
  mailBrandingContrastIsValid,
} from "@/server/email/mail-v2-workspace";

describe("mail-v2 brandingcontrast", () => {
  it("controleert elke publiceerbare statuskleur tegen wit op WCAG AA", () => {
    expect(mailBrandingContrastIsValid({
      primaryColor: "#17418B",
      secondaryColor: "#0B2E63",
      accentColor: "#2E69CC",
    })).toBe(true);
    expect(contrastRatio("#17418B", "#FFFFFF")).toBeGreaterThanOrEqual(4.5);
  });

  it("blokkeert een branding zodra één kleur onvoldoende contrast heeft", () => {
    expect(mailBrandingContrastIsValid({
      primaryColor: "#17418B",
      secondaryColor: "#0B2E63",
      accentColor: "#EEEEEE",
    })).toBe(false);
  });
});
