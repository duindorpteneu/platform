import { describe, expect, it } from "vitest";
import type { ExportPayload } from "@/lib/export-contract";
import { createCsvExport, createExportFilename, createXlsxExport, neutralizeSpreadsheetCell } from "@/server/exports/generate";

const payload: ExportPayload = {
  type: "members", seasonName: "2026 / 2027", generatedAt: "2026-07-18T10:00:00+02:00",
  columns: [{ key: "name", label: "Naam" }, { key: "active", label: "Actief" }],
  rows: [{ name: "=HYPERLINK(\"https://example.test\")", active: true }, { name: "+SUM(1,2)", active: false }],
};

describe("export generation", () => {
  it.each(["=x", "+x", "-x", "@x", "\tx", "\rx"])("neutralizes formula-sensitive value %j", (value) => expect(neutralizeSpreadsheetCell(value)).toBe(`'${value}`));
  it("creates BOM-prefixed, quoted CSV without active formulas", () => {
    const csv = createCsvExport(payload);
    expect(csv.startsWith("\uFEFF")).toBe(true);
    expect(csv).toContain("\"'=HYPERLINK(\"\"https://example.test\"\")\"");
    expect(csv).toContain("\"Ja\"");
  });
  it("creates a workbook and safe member-free filename", async () => {
    const xlsx = await createXlsxExport(payload);
    expect(xlsx.subarray(0, 2).toString()).toBe("PK");
    expect(createExportFilename(payload, "xlsx")).toBe("duindorp-sv-leden-2026-2027-2026-07-18.xlsx");
  });
});

