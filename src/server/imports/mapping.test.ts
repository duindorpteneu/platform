import { describe, expect, it } from "vitest";
import {
  dynamicImportMappingWorkspaceSchema,
  IMPORT_POLICY,
  importMappingSchema,
} from "@/lib/import-contract";
import {
  assertMappingHeaders,
  buildSizeDiagnostics,
  importHeaderHash,
  normalizeImportHeader,
  normalizeImportSize,
  normalizePresetEntries,
  selectedMappingForStorage,
} from "@/server/imports/mapping";

const articleId = "10000000-0000-4000-8000-000000000001";
const workspace = dynamicImportMappingWorkspaceSchema.parse({
  batchId: "20000000-0000-4000-8000-000000000001",
  seasonId: "30000000-0000-4000-8000-000000000001",
  revision: 0,
  catalogHash: "a".repeat(64),
  presets: [],
  articles: [{
    id: articleId,
    code: "BROEK",
    name: "Broek",
    importable: true,
    matchConflicts: [],
    variants: [{
      id: "40000000-0000-4000-8000-000000000001",
      label: "152",
      code: "BR-152",
      aliases: ["maat 152"],
    }],
  }],
});

describe("dynamische importmapping", () => {
  it("normaliseert headers en maten veilig en deterministisch", () => {
    expect(normalizeImportHeader("  Maat\u00a0Broek ")).toBe("maat broek");
    expect(normalizeImportSize("  maat\u00a0152 ")).toBe("MAAT 152");
    expect(importHeaderHash(["Naam", "Maat Broek"])).toMatch(/^[0-9a-f]{64}$/);
  });

  it("weigert dubbele doelen en een volledig genegeerde mapping", () => {
    expect(importMappingSchema.safeParse({
      policy: IMPORT_POLICY,
      entries: [
        { columnIndex: 0, sourceHeader: "A", target: { kind: "member_field", field: "email" } },
        { columnIndex: 1, sourceHeader: "B", target: { kind: "member_field", field: "email" } },
      ],
    }).success).toBe(false);
    expect(importMappingSchema.safeParse({
      policy: IMPORT_POLICY,
      entries: [{ columnIndex: 0, sourceHeader: "A", target: { kind: "ignore" } }],
    }).success).toBe(false);
  });

  it("bewaart alleen geselecteerde kolommen en uitsluitend een headerdigest", () => {
    const mapping = importMappingSchema.parse({
      policy: IMPORT_POLICY,
      entries: [
        { columnIndex: 0, sourceHeader: "Privé notitie", target: { kind: "ignore" } },
        { columnIndex: 1, sourceHeader: "Relatienummer", target: { kind: "member_field", field: "external_member_id" } },
      ],
    });
    const stored = selectedMappingForStorage(mapping);
    expect(stored).toHaveLength(1);
    expect(stored[0]).toEqual(expect.objectContaining({
      columnIndex: 1,
      sourceHeaderHash: expect.stringMatching(/^[0-9a-f]{64}$/),
    }));
    expect(JSON.stringify(stored)).not.toContain("Privé notitie");
    expect(JSON.stringify(stored)).not.toContain("Relatienummer");
  });

  it("controleert bronheaders exact tegen de opnieuw ontsleutelde CSV", () => {
    const mapping = importMappingSchema.parse({
      policy: IMPORT_POLICY,
      entries: [{ columnIndex: 0, sourceHeader: "Naam", target: { kind: "member_field", field: "first_name" } }],
    });
    expect(() => assertMappingHeaders(mapping, {
      delimiter: ";",
      headers: ["Andere naam"],
      records: [["Noa"]],
      rowShapeIssues: [],
    })).toThrow("DYNAMIC_IMPORT_HEADER_CHANGED");
  });

  it("onderscheidt code, label, alias, onbekend, leeg en onveilig zonder fuzzy match", () => {
    const mapping = importMappingSchema.parse({
      policy: IMPORT_POLICY,
      entries: [{
        columnIndex: 0,
        sourceHeader: "Maat Broek",
        target: { kind: "product_size", articleId },
      }],
    });
    const result = buildSizeDiagnostics(mapping, {
      delimiter: ";",
      headers: ["Maat Broek"],
      records: [["BR-152"], ["152"], ["maat 152"], ["153"], [""], ["=1+1"]],
      rowShapeIssues: [],
    }, workspace);
    expect(result[0]).toMatchObject({
      totalCount: 6,
      emptyCount: 1,
      recognizedCount: 3,
      unknownCount: 1,
      unsafeCount: 1,
    });
    expect(result[0]?.values).toEqual(expect.arrayContaining([
      expect.objectContaining({ rawValue: "BR-152", outcome: "recognized", matchedBy: "code" }),
      expect.objectContaining({ rawValue: "152", outcome: "recognized", matchedBy: "label" }),
      expect.objectContaining({ rawValue: "maat 152", outcome: "recognized", matchedBy: "alias" }),
      expect.objectContaining({ rawValue: "153", outcome: "unknown" }),
      expect.objectContaining({ rawValue: "=1+1", outcome: "unsafe" }),
    ]));
  });

  it("normaliseert presets en weigert dubbele bronheaders of doelen", () => {
    expect(normalizePresetEntries([{
      sourceHeaderKey: " Maat\u00a0Broek ",
      target: { kind: "product_size", articleId },
    }])).toEqual([{
      sourceHeaderKey: "maat broek",
      target: { kind: "product_size", articleId },
    }]);
    expect(() => normalizePresetEntries([
      { sourceHeaderKey: "E-mail", target: { kind: "member_field", field: "email" } },
      { sourceHeaderKey: " e-mail ", target: { kind: "member_field", field: "first_name" } },
    ])).toThrow("DYNAMIC_IMPORT_PRESET_INVALID");
  });
});
