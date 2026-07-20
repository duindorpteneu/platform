import { describe, expect, it } from "vitest";
import {
  bulkArticleSeasonRequestSchema,
  catalogArticleRequestSchema,
  catalogOrderWorkspaceSchema,
  catalogVariantRequestSchema,
  formatCentsForEuroInput,
  parseEuroAmountToCents,
  saveMemberOrderRequestSchema,
} from "@/lib/catalog-order-contract";

const id = "10000000-0000-4000-8000-000000000001";
const secondId = "10000000-0000-4000-8000-000000000002";

describe("catalogus- en bestelcontract", () => {
  it("normaliseert een artikel en weigert dubbele seizoenen", () => {
    const article = catalogArticleRequestSchema.parse({ articleId: null, name: "  Shirt ", code: " shirt_1 ", iconType: "shirt", active: true, sortOrder: 10, seasonIds: [id] });
    expect(article).toMatchObject({ name: "Shirt", code: "SHIRT_1" });
    expect(catalogArticleRequestSchema.safeParse({ ...article, seasonIds: [id, id] }).success).toBe(false);
  });

  it("normaliseert een lege leverancierscode naar null", () => {
    expect(catalogVariantRequestSchema.parse({ articleId: id, variantId: null, size: " 152 ", supplierCode: "  ", active: true, sortOrder: 1 })).toMatchObject({ size: "152", supplierCode: null });
  });

  it("converteert alleen ondubbelzinnige euro-invoer naar centen", () => {
    expect(parseEuroAmountToCents("87")).toBe(8_700);
    expect(parseEuroAmountToCents("87,5")).toBe(8_750);
    expect(parseEuroAmountToCents("87.50")).toBe(8_750);
    expect(parseEuroAmountToCents("1.000")).toBeNull();
    expect(parseEuroAmountToCents("12,345")).toBeNull();
    expect(parseEuroAmountToCents("-1")).toBeNull();
    expect(formatCentsForEuroInput(8_705)).toBe("87,05");
  });

  it("weigert dubbele varianten en ongeldige aantallen", () => {
    const input = { memberId: id, seasonId: secondId, amountDueCents: 8_700, lines: [{ variantId: id, quantity: 1 }] };
    expect(saveMemberOrderRequestSchema.safeParse(input).success).toBe(true);
    expect(saveMemberOrderRequestSchema.safeParse({ ...input, lines: [...input.lines, ...input.lines] }).success).toBe(false);
    expect(saveMemberOrderRequestSchema.safeParse({ ...input, lines: [{ variantId: id, quantity: 0 }] }).success).toBe(false);
  });

  it("weigert dubbele artikelen in een bulk-seizoenskoppeling", () => {
    expect(bulkArticleSeasonRequestSchema.safeParse({ seasonId: id, articleIds: [id, secondId], linked: true }).success).toBe(true);
    expect(bulkArticleSeasonRequestSchema.safeParse({ seasonId: id, articleIds: [secondId, secondId], linked: false }).success).toBe(false);
  });

  it("valideert de workspace strikt en weigert onverwachte PII", () => {
    const workspace = { activeSeason: { id, name: "2026/2027", defaultAmountCents: 8_700 }, seasons: [{ id, name: "2026/2027", status: "open", active: true }], articles: [], members: [] };
    expect(catalogOrderWorkspaceSchema.safeParse(workspace).success).toBe(true);
    expect(catalogOrderWorkspaceSchema.safeParse({ ...workspace, members: [{ id, name: "Lid", relationNumber: "DSV-1", team: "JO9-1", email: "niet@in.de.workspace", order: null }] }).success).toBe(false);
  });
});
