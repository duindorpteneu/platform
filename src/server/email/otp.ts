import { parentOtpEmailTemplateSchema, type ParentOtpEmailTemplate } from "@/lib/email-contract";
import { renderEmailTemplate } from "@/server/email/templates";

type OtpTemplateClient = {
  rpc(name: "get_parent_otp_email_template"): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

export async function getParentOtpEmailTemplate(client: OtpTemplateClient) {
  const { data, error } = await client.rpc("get_parent_otp_email_template");
  if (error) throw new Error("PARENT_OTP_EMAIL_TEMPLATE_UNAVAILABLE");
  const parsed = parentOtpEmailTemplateSchema.safeParse(data);
  if (!parsed.success) throw new Error("PARENT_OTP_EMAIL_TEMPLATE_INVALID");
  return parsed.data;
}

export function renderParentOtpEmail(template: ParentOtpEmailTemplate, code: string) {
  if (!/^\d{6}$/.test(code)) throw new Error("PARENT_OTP_CODE_INVALID");
  return renderEmailTemplate(
    template.subjectSource,
    template.bodySource,
    template.allowedShortcodes.map((shortcode) => shortcode.slice(2, -2)),
    {
      voornaam: "",
      volledige_naam: "",
      team: "",
      relatienummer: "",
      seizoen: "",
      bedrag: "",
      betaallink: "",
      qr_code: "",
      artikelen_af_te_halen: "",
      artikelen_nalevering: "",
      afhaallocatie: "",
      clubnaam: template.clubName,
      contact_email: template.contactEmail ?? "",
      verificatiecode: code,
      portaal_url: "",
    },
  );
}
