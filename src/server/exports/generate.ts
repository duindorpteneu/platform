import ExcelJS from "exceljs";
import type { ExportPayload, ExportType } from "@/lib/export-contract";

const FORMULA_PREFIX = /^[=+\-@\t\r]/;

export function neutralizeSpreadsheetCell(value: string) {
  return FORMULA_PREFIX.test(value) ? `'${value}` : value;
}

function displayValue(value: string | number | boolean | null) {
  if (value === null) return "";
  if (typeof value === "boolean") return value ? "Ja" : "Nee";
  return typeof value === "string" ? neutralizeSpreadsheetCell(value) : value;
}

function csvCell(value: string | number | boolean | null) {
  return `"${String(displayValue(value)).replaceAll('"', '""')}"`;
}

export function createCsvExport(payload: ExportPayload) {
  const lines = [
    payload.columns.map((column) => csvCell(column.label)).join(";"),
    ...payload.rows.map((row) => payload.columns.map((column) => csvCell(row[column.key] ?? null)).join(";")),
  ];
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}

export async function createXlsxExport(payload: ExportPayload) {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Duindorp SV Tenueportaal";
  workbook.created = new Date(payload.generatedAt);
  const sheet = workbook.addWorksheet("Export", { views: [{ state: "frozen", ySplit: 1 }] });
  sheet.columns = payload.columns.map((column) => ({ header: column.label, key: column.key, width: Math.min(45, Math.max(14, column.label.length + 4)) }));
  for (const source of payload.rows) {
    const row: Record<string, string | number> = {};
    for (const column of payload.columns) row[column.key] = displayValue(source[column.key] ?? null);
    sheet.addRow(row);
  }
  const header = sheet.getRow(1);
  header.font = { bold: true, color: { argb: "FFFFFFFF" } };
  header.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF0B2A5B" } };
  if (payload.columns.length > 0) sheet.autoFilter = { from: { row: 1, column: 1 }, to: { row: Math.max(1, sheet.rowCount), column: payload.columns.length } };
  return Buffer.from(await workbook.xlsx.writeBuffer());
}

const slugs: Record<ExportType, string> = {
  members: "leden", orders: "bestellingen", payments: "betalingen", deliveries: "leveringen", fulfilments: "uitgiftes", outstanding: "openstaand",
};

export function createExportFilename(payload: ExportPayload, extension: "csv" | "xlsx") {
  const season = (payload.seasonName ?? "alle-seizoenen").toLocaleLowerCase("nl-NL").normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  return `duindorp-sv-${slugs[payload.type]}-${season}-${payload.generatedAt.slice(0, 10)}.${extension}`;
}

