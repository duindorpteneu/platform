import { describe, expect, it } from "vitest";
import { EMAIL_SHORTCODES, fictionalEmailPreviewValues, renderEmailTemplate, validateTemplateForPurpose, validateTemplateSource } from "@/server/email/templates";

describe("e-mailtemplateveiligheid", () => {
  it("renders only allowlisted shortcodes and escapes HTML", () => {
    const values = { ...fictionalEmailPreviewValues(), volledige_naam: "<Sophie & Co>" };
    const rendered = renderEmailTemplate("Tenue {{volledige_naam}}", "Hallo {{volledige_naam}}", EMAIL_SHORTCODES, values);
    expect(rendered.text).toContain("<Sophie & Co>");
    expect(rendered.html).toContain("&lt;Sophie &amp; Co&gt;");
  });

  it("rejects unknown tokens, scripts and multiline subjects", () => {
    expect(() => validateTemplateSource("Hallo {{wachtwoord}}", "Tekst", EMAIL_SHORTCODES)).toThrow();
    expect(() => validateTemplateSource("Hallo", "<script>alert(1)</script>", EMAIL_SHORTCODES)).toThrow();
    expect(() => validateTemplateSource("Hallo\nwereld", "Tekst", EMAIL_SHORTCODES)).toThrow();
  });

  it("requires the transient verification-code shortcode in the OTP template", () => {
    expect(() => validateTemplateForPurpose("verification_code", "Uw code", "Tien minuten geldig.", ["verificatiecode"])).toThrow("EMAIL_VERIFICATION_CODE_REQUIRED");
    expect(() => validateTemplateForPurpose("verification_code", "Uw code", "Code: {{verificatiecode}}", ["verificatiecode"])).not.toThrow();
    expect(fictionalEmailPreviewValues().verificatiecode).toBe("123456");
  });

  it("requires a protected portal route in access invitations", () => {
    expect(() => validateTemplateForPurpose(
      "portal_access_invite",
      "Uw toegang",
      "Vraag zelf een code aan.",
      ["portaal_url"],
    )).toThrow("EMAIL_PORTAL_URL_REQUIRED");
    expect(() => validateTemplateForPurpose(
      "portal_access_invite",
      "Uw toegang",
      "Open {{portaal_url}} en vraag zelf een code aan.",
      ["portaal_url"],
    )).not.toThrow();
  });
});
