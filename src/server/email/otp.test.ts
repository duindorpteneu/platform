import { describe, expect, it } from "vitest";
import { getParentOtpEmailTemplate, renderParentOtpEmail } from "@/server/email/otp";

const template = {
  templateKey: "verification_code" as const,
  templateVersion: 3,
  subjectSource: "Uw code voor {{clubnaam}}",
  bodySource: "Code: {{verificatiecode}}. Vragen? {{contact_email}}",
  allowedShortcodes: ["{{verificatiecode}}", "{{clubnaam}}", "{{contact_email}}"],
  clubName: "Duindorp SV",
  contactEmail: "kleding@duindorpsv.nl",
};

describe("ouder-OTP e-mailtemplate", () => {
  it("reads and strictly validates the active database template", async () => {
    const client = { rpc: async () => ({ data: template, error: null }) };
    await expect(getParentOtpEmailTemplate(client)).resolves.toEqual(template);
  });

  it("renders the real code only in the transient message", () => {
    const rendered = renderParentOtpEmail(template, "654321");
    expect(rendered.subject).toBe("Uw code voor Duindorp SV");
    expect(rendered.text).toBe("Code: 654321. Vragen? kleding@duindorpsv.nl");
    expect(rendered.html).toContain("654321");
  });

  it("rejects invalid codes and malformed database responses", async () => {
    expect(() => renderParentOtpEmail(template, "12345")).toThrow("PARENT_OTP_CODE_INVALID");
    const client = { rpc: async () => ({ data: { ...template, extra: "leak" }, error: null }) };
    await expect(getParentOtpEmailTemplate(client)).rejects.toThrow("PARENT_OTP_EMAIL_TEMPLATE_INVALID");
  });
});
