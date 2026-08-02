import { z } from "zod";

export const EMAIL_SHORTCODES = ["voornaam", "volledige_naam", "team", "relatienummer", "seizoen", "bedrag", "betaallink", "qr_code", "artikelen_af_te_halen", "artikelen_nalevering", "afhaallocatie", "clubnaam", "contact_email", "verificatiecode", "portaal_url"] as const;
export const emailShortcodeSchema = z.enum(EMAIL_SHORTCODES);
export type EmailShortcode = z.infer<typeof emailShortcodeSchema>;
export type EmailTemplateValues = Record<EmailShortcode, string>;

const tokenPattern = /{{\s*([a-z_]+)\s*}}/g;

export function validateTemplateSource(subject: string, body: string, allowed: readonly string[]) {
  if (!subject.trim() || subject.length > 200 || /[\r\n]/.test(subject)) throw new Error("EMAIL_SUBJECT_INVALID");
  if (!body.trim() || body.length > 10_000 || /<[^>]+>|{{{|}}}/i.test(body)) throw new Error("EMAIL_BODY_INVALID");
  const allowlist = new Set(allowed);
  for (const source of [subject, body]) {
    for (const match of source.matchAll(tokenPattern)) {
      if (!emailShortcodeSchema.safeParse(match[1]).success || !allowlist.has(match[1])) throw new Error("EMAIL_SHORTCODE_NOT_ALLOWED");
    }
    const withoutKnown = source.replace(tokenPattern, "");
    if (withoutKnown.includes("{{") || withoutKnown.includes("}}")) throw new Error("EMAIL_TEMPLATE_SYNTAX_INVALID");
  }
}

export function validateTemplateForPurpose(templateKey: string, subject: string, body: string, allowed: readonly string[]) {
  validateTemplateSource(subject, body, allowed);
  if (templateKey === "verification_code" && !`${subject}\n${body}`.includes("{{verificatiecode}}")) {
    throw new Error("EMAIL_VERIFICATION_CODE_REQUIRED");
  }
  if (templateKey === "portal_access_invite" && !`${subject}\n${body}`.includes("{{portaal_url}}")) {
    throw new Error("EMAIL_PORTAL_URL_REQUIRED");
  }
}

function escapeHtml(value: string) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
}

function replace(source: string, values: EmailTemplateValues) {
  return source.replace(tokenPattern, (_token, key: EmailShortcode) => values[key] ?? "");
}

export function renderEmailTemplate(subject: string, body: string, allowed: readonly string[], values: EmailTemplateValues) {
  validateTemplateSource(subject, body, allowed);
  const renderedSubject = replace(subject, values).trim();
  const text = replace(body, values).trim();
  if (!renderedSubject || !text) throw new Error("EMAIL_RENDER_EMPTY");
  const html = `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#172033;white-space:pre-wrap">${escapeHtml(text)}</div>`;
  return { subject: renderedSubject, text, html };
}

export function fictionalEmailPreviewValues(): EmailTemplateValues {
  return {
    voornaam: "Sophie", volledige_naam: "Sophie de Bruin", team: "JO11-1", relatienummer: "DSV-0001",
    seizoen: "2026/27", bedrag: "€ 125,00", betaallink: "https://tenue.duindorpsv.nl/betaling/voorbeeld",
    qr_code: "Beschikbaar in het beveiligde tenueportaal", artikelen_af_te_halen: "Shirt maat 152",
    artikelen_nalevering: "Broekje maat 152", afhaallocatie: "Clubhuis Duindorp SV", clubnaam: "Duindorp SV",
    contact_email: "kledingcommissie@duindorpsv.nl",
    verificatiecode: "123456",
    portaal_url: "https://tenue.duindorpsv.nl/login",
  };
}
