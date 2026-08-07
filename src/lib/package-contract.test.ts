import { describe, expect, it } from "vitest";
import {
  formatPackagePrice,
  packageArchiveRequestSchema,
  packageDraftRequestSchema,
  packageSeasonRequiresExplicitDefault,
  packageWorkspaceSchema,
  parsePackagePriceToCents,
} from "@/lib/package-contract";

const seasonId = "81000000-0000-4000-8000-000000000001";
const articleId = "82000000-0000-4000-8000-000000000001";
const templateId = "83000000-0000-4000-8000-000000000001";
const revisionId = "84000000-0000-4000-8000-000000000001";
const contentHash = "a".repeat(64);

describe("pakketbeheercontract", () => {
  it("normaliseert een draft en bewaart geld uitsluitend als eurocenten", () => {
    const result = packageDraftRequestSchema.parse({
      templateId: null,
      revisionId: null,
      seasonId,
      key: " Keeper_Pakket ",
      name: " Keeper ",
      description: " Zelf beheerd ",
      priceCents: 12_950,
      items: [{ articleId, quantity: 1, sortOrder: 10 }],
      expectedHash: null,
    });
    expect(result).toMatchObject({ key: "keeper_pakket", name: "Keeper", priceCents: 12_950 });
    expect(parsePackagePriceToCents("129,50")).toBe(12_950);
    expect(formatPackagePrice(12_950)).toBe("129,50");
    expect(parsePackagePriceToCents("129,999")).toBeNull();
    expect(parsePackagePriceToCents("-1")).toBeNull();
  });

  it("weigert een losse template/revisie en dubbele producten", () => {
    const base = {
      templateId,
      revisionId,
      seasonId,
      key: "speler",
      name: "Speler",
      description: "",
      priceCents: 10_000,
      items: [{ articleId, quantity: 1, sortOrder: 10 }],
      expectedHash: contentHash,
    };
    expect(packageDraftRequestSchema.safeParse({ ...base, revisionId: null }).success).toBe(false);
    expect(packageDraftRequestSchema.safeParse({ ...base, items: [...base.items, ...base.items] }).success).toBe(false);
  });

  it("vereist een inhoudelijke archiveringsreden", () => {
    expect(packageArchiveRequestSchema.safeParse({ revisionId, reason: " vervangen ", expectedHash: contentHash }).success).toBe(true);
    expect(packageArchiveRequestSchema.safeParse({ revisionId, reason: "x", expectedHash: contentHash }).success).toBe(false);
  });

  it("valideert de beheerworkspace strikt en accepteert geen onverwachte velden", () => {
    const workspace = {
      activeSeason: { id: seasonId, name: "2026/2027" },
      seasons: [{ id: seasonId, name: "2026/2027", status: "open", active: true }],
      articles: [{
        id: articleId,
        name: "Broek",
        code: "BROEK",
        active: true,
        seasonIds: [seasonId],
        sizes: [{ id: "85000000-0000-4000-8000-000000000001", label: "152", active: true }],
      }],
      templates: [{
        id: templateId,
        seasonId,
        seasonName: "2026/2027",
        key: "speler",
        revisions: [{
          id: revisionId,
          revisionNumber: 1,
          name: "Speler",
          description: "",
          priceCents: 10_000,
          currency: "EUR",
          status: "draft",
          active: false,
          default: false,
          publishedAt: null,
          contentHash,
          items: [{ id: "86000000-0000-4000-8000-000000000001", articleId, quantity: 1, productName: "Broek", productCode: "BROEK", sortOrder: 10 }],
        }],
      }],
    };
    expect(packageWorkspaceSchema.safeParse(workspace).success).toBe(true);
    expect(packageWorkspaceSchema.safeParse({ ...workspace, parentEmail: "niet-toegestaan@example.test" }).success).toBe(false);
    const parsed = packageWorkspaceSchema.parse(workspace);
    expect(packageSeasonRequiresExplicitDefault(parsed, seasonId)).toBe(true);
    expect(packageSeasonRequiresExplicitDefault({
      ...parsed,
      templates: [{
        ...parsed.templates[0],
        revisions: [{
          ...parsed.templates[0].revisions[0],
          status: "published",
          active: true,
          default: true,
        }],
      }],
    }, seasonId)).toBe(false);
  });
});
