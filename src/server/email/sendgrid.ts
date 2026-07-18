export async function sendParentOtpEmail(recipientEmail: string, code: string) {
  const apiKey = process.env.SENDGRID_API_KEY;
  const fromEmail = process.env.SENDGRID_FROM_EMAIL;
  const templateId = process.env.SENDGRID_PARENT_OTP_TEMPLATE_ID;
  if (!apiKey || !fromEmail || !templateId) return { delivered: false as const, reason: "disabled" as const };

  const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      personalizations: [{ to: [{ email: recipientEmail }], dynamic_template_data: { verification_code: code } }],
      from: { email: fromEmail, name: "Duindorp SV Tenueportaal" },
      template_id: templateId,
    }),
  });
  if (!response.ok) return { delivered: false as const, reason: "provider_error" as const };
  return { delivered: true as const };
}
