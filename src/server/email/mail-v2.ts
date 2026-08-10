import sanitizeHtml from "sanitize-html";
import { z } from "zod";
import {
  MAIL_PROTECTED_NODE_KEYS,
  MAIL_SHORTCODE_KEYS,
  mailBrandingSchema,
  mailProtectedValueSchemas,
  mailTemplateSourceSchema,
  type MailBlockNode,
  type MailBranding,
  type MailInlineNode,
  type MailLine,
  type MailListNode,
  type MailMark,
  type MailProtectedNodeKey,
  type MailProtectedValues,
  type MailShortcodeKey,
  type MailShortcodeValues,
  type MailTemplateSource,
  type MailTipTapDocument,
} from "@/lib/mail-v2-contract";

const TOKEN_PATTERN = /\{\{([a-z][a-z0-9_]{2,63})\}\}/gu;
const SAFE_TEXT = /^[^\u0000-\u001f\u007f]{1,2000}$/u;
const SAFE_EMAIL = z.string().trim().email().max(254);

const SHORTCODE_VALUE_TYPES: Record<
  MailShortcodeKey,
  "text" | "email" | "money" | "url" | "integer"
> = {
  club_name: "text",
  recipient_name: "text",
  member_first_name: "text",
  member_full_name: "text",
  team_name: "text",
  season_name: "text",
  package_name: "text",
  package_amount: "money",
  payment_url: "url",
  portal_url: "url",
  size_confirm_url: "url",
  pickup_name: "text",
  pickup_address: "text",
  contact_email: "email",
  privacy_url: "url",
  otp_expiry_minutes: "integer",
};

const SANITIZE_OPTIONS: sanitizeHtml.IOptions = {
  allowedTags: [
    "div",
    "p",
    "h2",
    "h3",
    "ul",
    "ol",
    "li",
    "strong",
    "em",
    "a",
    "br",
    "table",
    "thead",
    "tbody",
    "tr",
    "th",
    "td",
    "span",
    "img",
  ],
  allowedAttributes: {
    "*": ["style"],
    a: ["href", "target", "rel"],
    img: ["src", "alt", "width", "height"],
    table: ["role"],
  },
  allowedSchemes: ["https", "http"],
  allowProtocolRelative: false,
  allowedStyles: {
    "*": {
      "background-color": [/^#[0-9A-F]{6}$/iu],
      color: [/^#[0-9A-F]{6}$/iu],
      display: [/^(block|inline|inline-block|none)$/u],
      "font-family": [/^[A-Za-z0-9"',.\-\s]+$/u],
      "font-size": [/^\d{1,2}px$/u],
      "font-weight": [/^(400|500|600|700)$/u],
      "letter-spacing": [/^-?\d(?:\.\d{1,2})?px$/u],
      "line-height": [/^(?:\d(?:\.\d{1,2})?|\d{1,2}px)$/u],
      margin: [/^(?:0|\d{1,2}px)(?: (?:0|\d{1,2}px)){0,3}$/u],
      "margin-bottom": [/^(?:0|\d{1,2}px)$/u],
      "margin-top": [/^(?:0|\d{1,2}px)$/u],
      padding: [/^(?:0|\d{1,2}px)(?: (?:0|\d{1,2}px)){0,3}$/u],
      "padding-bottom": [/^(?:0|\d{1,2}px)$/u],
      "padding-left": [/^(?:0|\d{1,2}px)$/u],
      "padding-right": [/^(?:0|\d{1,2}px)$/u],
      "padding-top": [/^(?:0|\d{1,2}px)$/u],
      "border-collapse": [/^collapse$/u],
      "border-radius": [/^\d{1,2}px$/u],
      "border-top": [/^1px solid #[0-9A-F]{6}$/iu],
      "border-bottom": [/^1px solid #[0-9A-F]{6}$/iu],
      "max-height": [/^(?:0|\d{1,2}px)$/u],
      "max-width": [/^\d{2,4}px$/u],
      opacity: [/^(?:0|1|0\.\d{1,2})$/u],
      overflow: [/^hidden$/u],
      "text-align": [/^(left|center|right)$/u],
      "text-decoration": [/^(none|underline)$/u],
      "vertical-align": [/^(top|middle)$/u],
      width: [/^(?:100%|\d{1,4}px)$/u],
    },
  },
  transformTags: {
    a: (_tagName, attributes) => ({
      tagName: "a",
      attribs: {
        ...attributes,
        target: "_blank",
        rel: "noopener noreferrer",
      },
    }),
  },
};

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function safeUrl(value: unknown) {
  if (typeof value !== "string" || value.length > 2_048) throw new Error("MAIL_V2_URL_INVALID");
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("MAIL_V2_URL_INVALID");
  }
  const localHttp = parsed.protocol === "http:"
    && (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1" || parsed.hostname === "::1");
  if (
    (parsed.protocol !== "https:" && !localHttp)
    || parsed.username
    || parsed.password
    || /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    throw new Error("MAIL_V2_URL_INVALID");
  }
  return parsed.toString();
}

function safeText(value: unknown, code = "MAIL_V2_VALUE_INVALID") {
  const normalized = typeof value === "number" ? String(value) : value;
  if (typeof normalized !== "string" || !SAFE_TEXT.test(normalized)) throw new Error(code);
  return normalized;
}

function shortcodeValue(key: MailShortcodeKey, values: MailShortcodeValues) {
  const value = values[key];
  if (value === undefined || value === null) throw new Error(`MAIL_V2_SHORTCODE_MISSING:${key}`);
  switch (SHORTCODE_VALUE_TYPES[key]) {
    case "email": {
      const parsed = SAFE_EMAIL.safeParse(value);
      if (!parsed.success) throw new Error("MAIL_V2_EMAIL_INVALID");
      return parsed.data;
    }
    case "url":
      return safeUrl(value);
    case "integer": {
      const normalized = typeof value === "number" ? value : Number(value);
      if (!Number.isSafeInteger(normalized) || normalized < 0 || normalized > 10_000) {
        throw new Error("MAIL_V2_INTEGER_INVALID");
      }
      return String(normalized);
    }
    case "money":
      return safeText(value, "MAIL_V2_MONEY_INVALID");
    case "text":
      return safeText(value);
  }
}

function renderTokenSource(
  source: string,
  allowed: readonly MailShortcodeKey[],
  values: MailShortcodeValues,
) {
  const allowedKeys = new Set(allowed);
  const rendered = source.replace(TOKEN_PATTERN, (_token, rawKey: string) => {
    const key = rawKey as MailShortcodeKey;
    if (!allowedKeys.has(key)) throw new Error("MAIL_V2_SHORTCODE_NOT_ALLOWED");
    return shortcodeValue(key, values);
  });
  const remainder = source.replace(TOKEN_PATTERN, "");
  if (/\{\{|\}\}/u.test(remainder)) throw new Error("MAIL_V2_SHORTCODE_SYNTAX_INVALID");
  return rendered;
}

function renderMarks(value: string, marks: readonly MailMark[] | undefined) {
  if (!marks) return value;
  return marks.reduce((result, mark) => {
    if (mark.type === "bold") return `<strong>${result}</strong>`;
    if (mark.type === "italic") return `<em>${result}</em>`;
    const href = escapeHtml(safeUrl(mark.attrs.href));
    return `<a href="${href}" target="_blank" rel="noopener noreferrer">${result}</a>`;
  }, value);
}

function renderInline(
  node: MailInlineNode,
  allowedShortcodes: readonly MailShortcodeKey[],
  values: MailShortcodeValues,
) {
  if (node.type === "hardBreak") return { html: "<br />", text: "\n" };
  if (node.type === "shortcode") {
    if (!allowedShortcodes.includes(node.attrs.key)) throw new Error("MAIL_V2_SHORTCODE_NOT_ALLOWED");
    const value = shortcodeValue(node.attrs.key, values);
    return { html: escapeHtml(value), text: value };
  }
  return {
    html: renderMarks(escapeHtml(node.text), node.marks),
    text: node.text,
  };
}

function formatMoney(amountCents: number) {
  return new Intl.NumberFormat("nl-NL", {
    style: "currency",
    currency: "EUR",
  }).format(amountCents / 100);
}

function hasMemberColumn(rows: readonly MailLine[]) {
  return new Set(rows.map((row) => row.memberFirstName).filter(Boolean)).size > 1;
}

function renderLineTable(
  title: string,
  value: z.infer<typeof mailProtectedValueSchemas.picked_up_items>,
) {
  const parsed = mailProtectedValueSchemas.picked_up_items.parse(value);
  const showMember = hasMemberColumn(parsed.rows);
  const headings = [
    ...(showMember ? ["Lid"] : []),
    "Product",
    "Maat",
    "Aantal",
    ...(parsed.rows.some((row) => row.status) ? ["Status"] : []),
  ];
  const includeStatus = headings.includes("Status");
  const rowHtml = parsed.rows.map((row) => {
    const cells = [
      ...(showMember ? [row.memberFirstName ?? ""] : []),
      row.product,
      row.size,
      String(row.quantity),
      ...(includeStatus ? [row.status ?? ""] : []),
    ];
    return `<tr>${cells.map((cell) => `<td style="border-bottom:1px solid #DDE3EC;padding:8px;text-align:left;vertical-align:top">${escapeHtml(cell)}</td>`).join("")}</tr>`;
  }).join("");
  const textRows = parsed.rows.map((row) => {
    const member = showMember ? `${row.memberFirstName ?? "Lid"}: ` : "";
    const quantity = row.quantity > 1 ? ` × ${row.quantity}` : "";
    return `- ${member}${row.product} — maat ${row.size}${quantity}${row.status ? ` — ${row.status}` : ""}`;
  }).join("\n");
  return {
    html: `<div style="margin:16px 0"><h3 style="color:#172033;font-size:16px;line-height:1.4;margin:0 0 8px">${escapeHtml(title)}</h3><table role="presentation" style="border-collapse:collapse;font-size:14px;line-height:1.5;width:100%"><thead><tr>${headings.map((heading) => `<th style="background-color:#EEF4FD;border-bottom:1px solid #DDE3EC;color:#0B2E63;font-weight:700;padding:8px;text-align:left">${heading}</th>`).join("")}</tr></thead><tbody>${rowHtml}</tbody></table></div>`,
    text: `${title}\n${textRows}`,
  };
}

function renderAction(url: string, label: string, primaryColor: string) {
  const safeHref = escapeHtml(safeUrl(url));
  const safeLabel = escapeHtml(safeText(label));
  return {
    html: `<p style="margin:16px 0"><a href="${safeHref}" target="_blank" rel="noopener noreferrer" style="background-color:${primaryColor};border-radius:8px;color:#FFFFFF;display:inline-block;font-weight:700;padding:12px 16px;text-decoration:none">${safeLabel}</a></p>`,
    text: `${label}: ${safeUrl(url)}`,
  };
}

function protectedValue<K extends MailProtectedNodeKey>(
  kind: K,
  values: MailProtectedValues,
): z.output<(typeof mailProtectedValueSchemas)[K]> {
  const value = values[kind];
  if (value === undefined) throw new Error(`MAIL_V2_PROTECTED_VALUE_MISSING:${kind}`);
  return mailProtectedValueSchemas[kind].parse(value) as z.output<(typeof mailProtectedValueSchemas)[K]>;
}

function renderProtectedBlock(
  kind: MailProtectedNodeKey,
  values: MailProtectedValues,
  branding: MailBranding,
) {
  switch (kind) {
    case "portal_route": {
      const value = protectedValue(kind, values);
      return renderAction(value.url, value.label, branding.primaryColor);
    }
    case "otp_code": {
      const value = protectedValue(kind, values);
      return {
        html: `<div style="background-color:#EEF4FD;border-radius:8px;color:#0B2E63;font-size:28px;font-weight:700;letter-spacing:6px;margin:16px 0;padding:16px;text-align:center">${value.code}</div>`,
        text: `Verificatiecode: ${value.code}`,
      };
    }
    case "otp_validity": {
      const value = protectedValue(kind, values);
      return {
        html: `<p style="color:#172033;font-size:14px;line-height:1.6;margin:12px 0">Deze code is ${value.minutes} minuten geldig en kan één keer worden gebruikt.</p>`,
        text: `Deze code is ${value.minutes} minuten geldig en kan één keer worden gebruikt.`,
      };
    }
    case "otp_warning": {
      protectedValue(kind, values);
      const warning = "Deel deze code nooit. Een medewerker vraagt niet om uw verificatiecode.";
      return {
        html: `<p style="background-color:#FFF7ED;color:#7C2D12;font-size:14px;line-height:1.6;margin:12px 0;padding:12px">${warning}</p>`,
        text: warning,
      };
    }
    case "size_table":
      return renderLineTable("Pakketmaten", protectedValue(kind, values));
    case "size_action": {
      const value = protectedValue(kind, values);
      return renderAction(value.url, value.label, branding.primaryColor);
    }
    case "payment_summary": {
      const value = protectedValue(kind, values);
      if ("orders" in value) {
        const rows = value.orders.map((order) => ({
          ...order,
          amount: formatMoney(order.amountCents),
        }));
        return {
          html: `<div style="background-color:#EEF4FD;border-radius:8px;margin:16px 0;padding:16px"><table role="presentation" style="border-collapse:collapse;width:100%"><tbody>${rows.map((order) => `<tr><td style="border-bottom:1px solid #DDE3EC;color:#0B2E63;font-size:14px;font-weight:700;padding:8px 0">${escapeHtml(order.memberFirstName)} · ${escapeHtml(order.packageName)}</td><td style="border-bottom:1px solid #DDE3EC;color:#172033;font-size:14px;font-weight:700;padding:8px 0;text-align:right">${escapeHtml(order.amount)}</td></tr>`).join("")}</tbody></table><p style="color:#172033;font-size:12px;line-height:1.6;margin:12px 0 0">Ieder pakket wordt afzonderlijk en voor het exact vermelde bedrag betaald.</p></div>`,
          text: `${rows.map((order) => `${order.memberFirstName} · ${order.packageName}: ${order.amount}`).join("\n")}\nIeder pakket wordt afzonderlijk en voor het exact vermelde bedrag betaald.`,
        };
      }
      const amount = formatMoney(value.amountCents);
      return {
        html: `<div style="background-color:#EEF4FD;border-radius:8px;margin:16px 0;padding:16px"><p style="color:#0B2E63;font-size:14px;font-weight:700;margin:0 0 8px">${escapeHtml(value.packageName)}</p><p style="color:#172033;font-size:20px;font-weight:700;margin:0">${escapeHtml(amount)}</p></div>`,
        text: `${value.packageName}: ${amount}`,
      };
    }
    case "payment_action": {
      const value = protectedValue(kind, values);
      return renderAction(value.url, value.label, branding.primaryColor);
    }
    case "ready_items":
      return renderLineTable("Afhaalklaar", protectedValue(kind, values));
    case "stock_items":
      return renderLineTable("Voorraadstatus", protectedValue(kind, values));
    case "picked_up_items":
      return renderLineTable("Nu afgehaald", protectedValue(kind, values));
    case "remaining_items":
      return renderLineTable("Nog te leveren", protectedValue(kind, values));
    case "full_package":
      return renderLineTable("Volledig pakket", protectedValue(kind, values));
    case "pickup_location": {
      const value = protectedValue(kind, values);
      return {
        html: `<div style="background-color:#EEF4FD;border-radius:8px;margin:16px 0;padding:16px"><p style="color:#0B2E63;font-size:14px;font-weight:700;margin:0 0 8px">${escapeHtml(value.name)}</p><p style="color:#172033;font-size:14px;line-height:1.6;margin:0">${escapeHtml(value.address)}</p></div>`,
        text: `Afhalen bij ${value.name}, ${value.address}`,
      };
    }
    case "pickup_qr": {
      const value = protectedValue(kind, values);
      return renderAction(
        value.portalUrl,
        "Open het portaal voor de actieve afhaal-QR",
        branding.primaryColor,
      );
    }
    case "failure_reference": {
      const value = protectedValue(kind, values);
      return {
        html: `<div style="background-color:#FFF7ED;color:#7C2D12;font-size:14px;line-height:1.6;margin:16px 0;padding:12px"><strong>Job</strong> ${escapeHtml(value.jobId)}<br /><strong>Reden</strong> ${escapeHtml(value.reason)}</div>`,
        text: `Job ${value.jobId}\nReden ${value.reason}`,
      };
    }
  }
}

function renderList(
  node: MailListNode,
  source: MailTemplateSource,
  shortcodes: MailShortcodeValues,
  protectedValues: MailProtectedValues,
  branding: MailBranding,
): { html: string; text: string } {
  const tag = node.type === "orderedList" ? "ol" : "ul";
  const items = node.content.map((item) => {
    const content = item.content.map((child) => {
      if (child.type === "paragraph") {
        const inline = child.content.map((part) => renderInline(part, source.allowedShortcodes, shortcodes));
        return {
          html: inline.map((part) => part.html).join(""),
          text: inline.map((part) => part.text).join(""),
        };
      }
      return renderList(child, source, shortcodes, protectedValues, branding);
    });
    return {
      html: `<li>${content.map((part) => part.html).join("")}</li>`,
      text: content.map((part) => part.text).join(" "),
    };
  });
  return {
    html: `<${tag} style="color:#172033;font-size:15px;line-height:1.6;margin:12px 0;padding-left:24px">${items.map((item) => item.html).join("")}</${tag}>`,
    text: items.map((item, index) => `${tag === "ol" ? `${index + 1}.` : "-"} ${item.text}`).join("\n"),
  };
}

function renderBlock(
  node: MailBlockNode,
  source: MailTemplateSource,
  shortcodes: MailShortcodeValues,
  protectedValues: MailProtectedValues,
  branding: MailBranding,
) {
  if (node.type === "protectedBlock") {
    if (!source.allowedProtectedNodes.includes(node.attrs.kind)) {
      throw new Error("MAIL_V2_PROTECTED_NODE_NOT_ALLOWED");
    }
    return renderProtectedBlock(node.attrs.kind, protectedValues, branding);
  }
  if (node.type === "bulletList" || node.type === "orderedList") {
    return renderList(node, source, shortcodes, protectedValues, branding);
  }
  const inline = node.content.map((part) => renderInline(part, source.allowedShortcodes, shortcodes));
  const bodyHtml = inline.map((part) => part.html).join("");
  const bodyText = inline.map((part) => part.text).join("");
  if (node.type === "heading") {
    const tag = node.attrs.level === 2 ? "h2" : "h3";
    const size = node.attrs.level === 2 ? "20px" : "16px";
    return {
      html: `<${tag} style="color:#0B2E63;font-size:${size};line-height:1.4;margin:20px 0 8px">${bodyHtml}</${tag}>`,
      text: bodyText,
    };
  }
  return {
    html: `<p style="color:#172033;font-size:15px;line-height:1.6;margin:12px 0">${bodyHtml || "<br />"}</p>`,
    text: bodyText,
  };
}

function assertDocumentContract(document: MailTipTapDocument, source: MailTemplateSource) {
  const shortcodeKeys: MailShortcodeKey[] = [];
  const protectedKeys: MailProtectedNodeKey[] = [];
  const visit = (node: MailTipTapDocument | MailBlockNode | MailInlineNode | { content: unknown[] }) => {
    if ("type" in node && node.type === "shortcode") shortcodeKeys.push(node.attrs.key);
    if ("type" in node && node.type === "protectedBlock") protectedKeys.push(node.attrs.kind);
    if ("content" in node && Array.isArray(node.content)) {
      node.content.forEach((child) => visit(child as MailBlockNode | MailInlineNode | { content: unknown[] }));
    }
  };
  visit(document);
  if (shortcodeKeys.some((key) => !source.allowedShortcodes.includes(key))) {
    throw new Error("MAIL_V2_SHORTCODE_NOT_ALLOWED");
  }
  if (protectedKeys.some((key) => !source.allowedProtectedNodes.includes(key))) {
    throw new Error("MAIL_V2_PROTECTED_NODE_NOT_ALLOWED");
  }
  for (const required of source.requiredProtectedNodes) {
    if (protectedKeys.filter((key) => key === required).length !== 1) {
      throw new Error(`MAIL_V2_PROTECTED_NODE_REQUIRED:${required}`);
    }
  }
}

function canonicalSanitize(rawHtml: string) {
  const sanitized = sanitizeHtml(rawHtml, SANITIZE_OPTIONS);
  if (sanitizeHtml(sanitized, SANITIZE_OPTIONS) !== sanitized) {
    throw new Error("MAIL_V2_SANITIZER_NOT_IDEMPOTENT");
  }
  return sanitized;
}

export function renderMailV2Body(input: {
  source: MailTemplateSource;
  branding: MailBranding;
  shortcodes: MailShortcodeValues;
  protectedValues: MailProtectedValues;
}) {
  const source = mailTemplateSourceSchema.parse(input.source);
  const branding = mailBrandingSchema.parse(input.branding);
  assertDocumentContract(source.bodyTipTap, source);
  const blocks = source.bodyTipTap.content.map((node) => renderBlock(
    node,
    source,
    input.shortcodes,
    input.protectedValues,
    branding,
  ));
  return {
    html: canonicalSanitize(blocks.map((block) => block.html).join("")),
    text: blocks.map((block) => block.text).filter(Boolean).join("\n\n"),
  };
}

export function renderMailV2(input: {
  source: MailTemplateSource;
  branding: MailBranding;
  shortcodes: MailShortcodeValues;
  protectedValues: MailProtectedValues;
  appBaseUrl: string;
}) {
  const source = mailTemplateSourceSchema.parse(input.source);
  const branding = mailBrandingSchema.parse(input.branding);
  const subject = renderTokenSource(source.subjectSource, source.allowedShortcodes, input.shortcodes).trim();
  const preheader = renderTokenSource(source.preheaderSource, source.allowedShortcodes, input.shortcodes).trim();
  if (!subject || !preheader || /[\r\n]/u.test(subject) || /[\r\n]/u.test(preheader)) {
    throw new Error("MAIL_V2_HEADER_INVALID");
  }
  const body = renderMailV2Body({
    source,
    branding,
    shortcodes: input.shortcodes,
    protectedValues: input.protectedValues,
  });
  const logoUrl = safeUrl(new URL(branding.logoAssetPath, safeUrl(input.appBaseUrl)).toString());
  const privacyUrl = safeUrl(branding.privacyUrl);
  const html = canonicalSanitize(
    `<div style="background-color:#F6F8FB;padding:24px"><div style="display:none;max-height:0;opacity:0;overflow:hidden">${escapeHtml(preheader)}</div><table role="presentation" style="border-collapse:collapse;margin:0;width:100%"><tbody><tr><td style="padding:0;text-align:center"><table role="presentation" style="background-color:#FFFFFF;border-collapse:collapse;margin:0;max-width:640px;width:100%"><tbody><tr><td style="background-color:${branding.secondaryColor};padding:20px 24px"><img src="${escapeHtml(logoUrl)}" alt="Duindorp SV" width="56" height="56" /></td></tr><tr><td style="padding:24px">${body.html}</td></tr><tr><td style="border-top:1px solid #DDE3EC;color:#172033;font-size:12px;line-height:1.6;padding:20px 24px"><p style="margin:0 0 8px">${escapeHtml(branding.footerText)}</p><p style="margin:0"><a href="${escapeHtml(privacyUrl)}" target="_blank" rel="noopener noreferrer" style="color:${branding.primaryColor};text-decoration:underline">Privacy</a></p></td></tr></tbody></table></td></tr></tbody></table></div>`,
  );
  return {
    subject,
    preheader,
    html,
    text: `${body.text}\n\n${branding.footerText}\nPrivacy: ${privacyUrl}`.trim(),
    fromName: branding.fromName,
    fromEmail: branding.fromEmail,
    replyToEmail: branding.replyToEmail,
  };
}

export function mailV2PreviewData(): {
  shortcodes: Record<MailShortcodeKey, string | number>;
  protectedValues: Required<MailProtectedValues>;
} {
  const exampleRows = [{
    memberFirstName: "Sophie",
    product: "Wedstrijdshirt",
    size: "152",
    quantity: 1,
    status: "Af te halen",
  }];
  return {
    shortcodes: {
      club_name: "Duindorp SV",
      recipient_name: "Familie De Bruin",
      member_first_name: "Sophie",
      member_full_name: "Sophie de Bruin",
      team_name: "JO11-1",
      season_name: "2026/27",
      package_name: "Voorbeeldpakket",
      package_amount: "€ 125,00",
      payment_url: "https://tenue.duindorpsv.nl/betaling/voorbeeld",
      portal_url: "https://tenue.duindorpsv.nl/mijn-tenue",
      size_confirm_url: "https://tenue.duindorpsv.nl/mijn-tenue",
      pickup_name: "Free-Kick Sport",
      pickup_address: "De Savornin Lohmanplein 45, 2566 AE Den Haag",
      contact_email: "kleding@duindorpsv.nl",
      privacy_url: "https://duindorpsv.nl/privacy",
      otp_expiry_minutes: 10,
    },
    protectedValues: {
      portal_route: {
        url: "https://tenue.duindorpsv.nl/login",
        label: "Open het tenueportaal",
      },
      otp_code: { code: "123456" },
      otp_validity: { minutes: 10 },
      otp_warning: {},
      size_table: { rows: exampleRows },
      size_action: {
        url: "https://tenue.duindorpsv.nl/mijn-tenue",
        label: "Maten controleren",
      },
      payment_summary: {
        packageName: "Voorbeeldpakket",
        amountCents: 12_500,
        currency: "EUR",
      },
      payment_action: {
        url: "https://tenue.duindorpsv.nl/betaling/voorbeeld",
        label: "Veilig betalen",
      },
      ready_items: { rows: exampleRows },
      stock_items: { rows: exampleRows },
      picked_up_items: { rows: exampleRows },
      remaining_items: {
        rows: [{ ...exampleRows[0], product: "Wedstrijdbroek", status: "Nalevering" }],
      },
      full_package: { rows: exampleRows },
      pickup_location: {
        name: "Free-Kick Sport",
        address: "De Savornin Lohmanplein 45, 2566 AE Den Haag",
      },
      pickup_qr: {
        portalUrl: "https://tenue.duindorpsv.nl/mijn-tenue",
      },
      failure_reference: {
        jobId: "e6600000-0000-4000-8000-000000000099",
        reason: "provider_rejected",
      },
    },
  };
}

export function mailV2TemplatePreview(input: {
  source: MailTemplateSource;
  branding: MailBranding;
  appBaseUrl: string;
}) {
  const preview = mailV2PreviewData();
  return renderMailV2({
    ...input,
    shortcodes: preview.shortcodes,
    protectedValues: preview.protectedValues,
  });
}

export function assertMailV2CatalogIsComplete(keys: readonly string[]) {
  if (
    keys.length !== MAIL_SHORTCODE_KEYS.length
    || new Set(keys).size !== keys.length
    || MAIL_SHORTCODE_KEYS.some((key) => !keys.includes(key))
    || MAIL_PROTECTED_NODE_KEYS.length !== 16
  ) {
    throw new Error("MAIL_V2_CATALOG_INCOMPLETE");
  }
}
