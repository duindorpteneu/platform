import { describe, expect, it } from "vitest";
import { EMAIL_SHORTCODES, fictionalEmailPreviewValues, renderEmailTemplate, validateTemplateSource } from "@/server/email/templates";

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
});
