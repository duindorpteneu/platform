import { describe, expect, it } from "vitest";
import {
  DEFAULT_MAIL_QUIET_END,
  DEFAULT_MAIL_QUIET_START,
  MAIL_TEMPLATE_KEYS,
  mailTipTapDocumentSchema,
} from "@/lib/mail-v2-contract";

describe("mail-v2 basiscontract", () => {
  it("houdt nieuwe planners inactief met de canonieke stille uren", () => {
    expect(DEFAULT_MAIL_QUIET_START).toBe("20:00");
    expect(DEFAULT_MAIL_QUIET_END).toBe("08:00");
  });

  it("bevat de volledige minimale mailcatalogus zonder dubbelen", () => {
    expect(MAIL_TEMPLATE_KEYS).toHaveLength(19);
    expect(new Set(MAIL_TEMPLATE_KEYS).size).toBe(19);
  });

  it("normaliseert de geldige lege slotparagraaf uit TipTap", () => {
    expect(mailTipTapDocumentSchema.parse({
      type: "doc",
      content: [
        { type: "protectedBlock", attrs: { kind: "otp_warning" } },
        { type: "paragraph" },
      ],
    })).toEqual({
      type: "doc",
      content: [
        { type: "protectedBlock", attrs: { kind: "otp_warning" } },
        { type: "paragraph", content: [] },
      ],
    });
  });
});
