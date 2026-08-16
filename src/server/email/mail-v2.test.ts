import { describe, expect, it } from "vitest";
import {
  mailTipTapDocumentSchema,
  type MailBranding,
  type MailTemplateSource,
} from "@/lib/mail-v2-contract";
import {
  mailV2PreviewData,
  renderMailV2,
  renderMailV2Body,
} from "@/server/email/mail-v2";

const branding: MailBranding = {
  clubName: "Duindorp SV",
  logoAssetPath: "/duindorp-sv-logo.png",
  fromName: "Kledingcommissie Duindorp SV",
  fromEmail: "kleding@duindorpsv.nl",
  replyToEmail: "kleding@duindorpsv.nl",
  contactEmail: "kleding@duindorpsv.nl",
  clubAddressLine: "Houtrustlaan 1",
  clubPostalCode: "2566 ZW",
  clubCity: "Den Haag",
  pickupName: "Free-Kick Sport",
  pickupAddressLine: "De Savornin Lohmanplein 45",
  pickupPostalCode: "2566 AE",
  pickupCity: "Den Haag",
  privacyUrl: "https://duindorpsv.nl/privacy",
  primaryColor: "#17418B",
  secondaryColor: "#0B2E63",
  accentColor: "#2E69CC",
  footerText: "Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy",
  contrastValidated: true,
};

const partialSource: MailTemplateSource = {
  templateKey: "partial_pickup",
  subjectSource: "Deel afgehaald voor {{member_first_name}}",
  preheaderSource: "Bekijk wat nu is afgehaald en wat nog volgt.",
  bodyTipTap: {
    type: "doc",
    content: [
      {
        type: "paragraph",
        content: [
          { type: "text", text: "Beste " },
          { type: "shortcode", attrs: { key: "member_first_name" } },
        ],
      },
      { type: "protectedBlock", attrs: { kind: "picked_up_items" } },
      { type: "protectedBlock", attrs: { kind: "remaining_items" } },
    ],
  },
  allowedShortcodes: [
    "club_name",
    "member_first_name",
    "season_name",
    "portal_url",
    "contact_email",
    "privacy_url",
  ],
  allowedProtectedNodes: ["picked_up_items", "remaining_items"],
  requiredProtectedNodes: ["picked_up_items", "remaining_items"],
};

describe("mail-v2 renderer", () => {
  it("renders deterministic sanitized HTML, text and immutable sender fields", () => {
    const preview = mailV2PreviewData();
    const first = renderMailV2({
      source: partialSource,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
      appBaseUrl: "https://tenue.duindorpsv.nl",
    });
    const second = renderMailV2({
      source: partialSource,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
      appBaseUrl: "https://tenue.duindorpsv.nl",
    });

    expect(second).toEqual(first);
    expect(first.subject).toBe("Deel afgehaald voor Sophie");
    expect(first.preheader).toBe("Bekijk wat nu is afgehaald en wat nog volgt.");
    expect(first.html).toContain("Nu afgehaald");
    expect(first.html).toContain("Nog te leveren");
    expect(first.html).toContain("/duindorp-sv-logo.png");
    expect(first.text).toContain("Privacy: https://duindorpsv.nl/privacy");
    expect(first.fromName).toBe("Kledingcommissie Duindorp SV");
    expect(first.fromEmail).toBe("kleding@duindorpsv.nl");
    expect(first.replyToEmail).toBe("kleding@duindorpsv.nl");
    expect(first.html).not.toMatch(/<script|onerror|javascript:/iu);
  });

  it("escapes member and product values in every HTML context", () => {
    const preview = mailV2PreviewData();
    const rendered = renderMailV2({
      source: partialSource,
      branding,
      shortcodes: {
        ...preview.shortcodes,
        member_first_name: '"><img src=x onerror=alert(1)>',
      },
      protectedValues: {
        ...preview.protectedValues,
        picked_up_items: {
          rows: [{
            product: 'Shirt"><svg onload=alert(1)>',
            size: "<script>alert(1)</script>",
            quantity: 1,
          }],
        },
      },
      appBaseUrl: "https://tenue.duindorpsv.nl",
    });

    expect(rendered.html).toContain("&lt;img");
    expect(rendered.html).toContain("&lt;svg");
    expect(rendered.html).toContain("&lt;script&gt;");
    expect(rendered.html).not.toMatch(/<(?:svg|script)(?:\s|>)|<img\s+src=x|<[^>]+\sonerror=/iu);
  });

  it("rejects missing, duplicate and non-allowlisted protected nodes", () => {
    const preview = mailV2PreviewData();
    expect(() => renderMailV2Body({
      source: {
        ...partialSource,
        bodyTipTap: {
          type: "doc",
          content: [{ type: "protectedBlock", attrs: { kind: "picked_up_items" } }],
        },
      },
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
    })).toThrow("MAIL_V2_PROTECTED_NODE_REQUIRED:remaining_items");

    expect(() => renderMailV2Body({
      source: {
        ...partialSource,
        bodyTipTap: {
          type: "doc",
          content: [
            { type: "protectedBlock", attrs: { kind: "picked_up_items" } },
            { type: "protectedBlock", attrs: { kind: "remaining_items" } },
            { type: "protectedBlock", attrs: { kind: "remaining_items" } },
          ],
        },
      },
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
    })).toThrow("MAIL_V2_PROTECTED_NODE_REQUIRED:remaining_items");

    expect(() => renderMailV2Body({
      source: {
        ...partialSource,
        bodyTipTap: {
          type: "doc",
          content: [
            { type: "protectedBlock", attrs: { kind: "picked_up_items" } },
            { type: "protectedBlock", attrs: { kind: "remaining_items" } },
            { type: "protectedBlock", attrs: { kind: "otp_code" } },
          ],
        },
      },
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
    })).toThrow("MAIL_V2_PROTECTED_NODE_NOT_ALLOWED");
  });

  it("rejects unsafe links including credentials and non-HTTPS schemes", () => {
    const preview = mailV2PreviewData();
    const linkedSource: MailTemplateSource = {
      ...partialSource,
      bodyTipTap: {
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [{
              type: "text",
              text: "Onveilig",
              marks: [{ type: "link", attrs: { href: "javascript:alert(1)" } }],
            }],
          },
          { type: "protectedBlock", attrs: { kind: "picked_up_items" } },
          { type: "protectedBlock", attrs: { kind: "remaining_items" } },
        ],
      },
    };
    expect(() => renderMailV2Body({
      source: linkedSource,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
    })).toThrow("MAIL_V2_URL_INVALID");

    for (const unsafe of [
      "data:text/html,alert(1)",
      "vbscript:alert(1)",
      "https://user:password@example.com/path",
      "http://example.com/path",
      "//example.com/path",
    ]) {
      expect(() => renderMailV2({
        source: partialSource,
        branding,
        shortcodes: { ...preview.shortcodes, portal_url: unsafe },
        protectedValues: preview.protectedValues,
        appBaseUrl: "https://tenue.duindorpsv.nl",
      })).not.toThrow();
      expect(() => renderMailV2({
        source: {
          ...partialSource,
          subjectSource: "Open {{portal_url}}",
        },
        branding,
        shortcodes: { ...preview.shortcodes, portal_url: unsafe },
        protectedValues: preview.protectedValues,
        appBaseUrl: "https://tenue.duindorpsv.nl",
      })).toThrow("MAIL_V2_URL_INVALID");
    }
  });

  it("accepts localhost HTTP only for local rendering", () => {
    const preview = mailV2PreviewData();
    expect(() => renderMailV2({
      source: partialSource,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
      appBaseUrl: "http://localhost:3100",
    })).not.toThrow();
  });

  it("validates the closed TipTap AST and its limits", () => {
    expect(mailTipTapDocumentSchema.safeParse({
      type: "doc",
      content: [{ type: "html", content: "<script>alert(1)</script>" }],
    }).success).toBe(false);
    expect(mailTipTapDocumentSchema.safeParse({
      type: "doc",
      content: [{
        type: "paragraph",
        content: [{ type: "text", text: "{{otp_code}}" }],
      }],
    }).success).toBe(false);
    expect(mailTipTapDocumentSchema.safeParse({
      type: "doc",
      content: [{
        type: "paragraph",
        content: [{ type: "text", text: "a".repeat(4_001) }],
      }],
    }).success).toBe(false);
    expect(mailTipTapDocumentSchema.safeParse({
      type: "doc",
      content: Array.from({ length: 101 }, () => ({
        type: "paragraph",
        content: [{ type: "text", text: "Te veel" }],
      })),
    }).success).toBe(false);
  });

  it("renders OTP exclusively through its three protected nodes", () => {
    const preview = mailV2PreviewData();
    const bodyTipTap = mailTipTapDocumentSchema.parse({
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "Log veilig in." }] },
        { type: "protectedBlock", attrs: { kind: "otp_code" } },
        { type: "protectedBlock", attrs: { kind: "otp_validity" } },
        { type: "protectedBlock", attrs: { kind: "otp_warning" } },
        // TipTap keeps a cursor paragraph after a trailing atomic node.
        { type: "paragraph" },
      ],
    });
    const source: MailTemplateSource = {
      templateKey: "login_otp",
      subjectSource: "Uw verificatiecode voor het tenueportaal van {{club_name}}",
      preheaderSource: "Tien minuten geldig.",
      bodyTipTap,
      allowedShortcodes: ["club_name", "otp_expiry_minutes"],
      allowedProtectedNodes: ["otp_code", "otp_validity", "otp_warning"],
      requiredProtectedNodes: ["otp_code", "otp_validity", "otp_warning"],
    };
    const rendered = renderMailV2({
      source,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
      appBaseUrl: "https://tenue.duindorpsv.nl",
    });
    expect(rendered.subject).toBe("Uw verificatiecode voor het tenueportaal van Duindorp SV");
    expect(rendered.html).toContain("123456");
    expect(rendered.html).toContain("10 minuten geldig");
    expect(rendered.html).toContain("Deel deze code nooit.");
    expect(rendered.html).not.toContain("Een medewerker vraagt niet om uw verificatiecode.");
    expect(rendered.text).toContain("Verificatiecode: 123456");
    expect(rendered.text).toContain("Deel deze code nooit.");
  });

  it("keeps final package mail free of partial-pickup blocks", () => {
    const preview = mailV2PreviewData();
    const source: MailTemplateSource = {
      templateKey: "package_complete",
      subjectSource: "Pakket compleet voor {{member_first_name}}",
      preheaderSource: "Alles is afgehaald.",
      bodyTipTap: {
        type: "doc",
        content: [
          { type: "paragraph", content: [{ type: "text", text: "Het pakket is compleet." }] },
          { type: "protectedBlock", attrs: { kind: "full_package" } },
        ],
      },
      allowedShortcodes: ["member_first_name", "season_name"],
      allowedProtectedNodes: ["full_package"],
      requiredProtectedNodes: ["full_package"],
    };
    const rendered = renderMailV2({
      source,
      branding,
      shortcodes: preview.shortcodes,
      protectedValues: preview.protectedValues,
      appBaseUrl: "https://tenue.duindorpsv.nl",
    });
    expect(rendered.html).toContain("Volledig pakket");
    expect(rendered.html).not.toContain("Nu afgehaald");
    expect(rendered.html).not.toContain("Nog te leveren");
  });
});
