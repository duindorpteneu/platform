import { z } from "zod";

export const SPORTLINK_MAX_BYTES = 10 * 1024 * 1024;
const MAX_ROWS = 10_000;
const MAX_COLUMNS = 32;
const MAX_CELL_LENGTH = 512;

const memberSchema = z.object({
  relationNumber: z.string().min(1).max(80),
  firstName: z.string().min(1).max(120),
  insertion: z.string().max(80).nullable(),
  lastName: z.string().min(1).max(120),
  email: z.string().email().max(320),
  team: z.string().min(1).max(120),
  activeForSeason: z.boolean(),
});

export type SportlinkMember = z.infer<typeof memberSchema>;
export type ImportIssue = { row: number; field?: string; message: string };
export type ImportPreview = {
  members: SportlinkMember[];
  issues: ImportIssue[];
  summary: { total: number; valid: number; invalid: number; duplicates: number };
  delimiter: "," | ";";
};

const headerAliases: Record<keyof SportlinkMember, string[]> = {
  relationNumber: ["relatienummer", "relatienr", "relatie nr", "relatiecode"],
  firstName: ["voornaam", "first name"],
  insertion: ["tussenvoegsel", "insertion"],
  lastName: ["achternaam", "last name"],
  email: ["e-mailadres", "emailadres", "e-mail", "email"],
  team: ["team", "teamnaam", "team naam"],
  activeForSeason: ["actief voor seizoen", "actief", "active for season"],
};

function normalizeHeader(value: string) {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function normalizeEmail(value: string) {
  return value.trim().toLowerCase();
}

function normalizeRelationNumber(value: string) {
  return value.trim().toUpperCase();
}

function isFormulaLike(value: string) {
  return /^[=+\-@\t\r]/.test(value.trim());
}

function detectDelimiter(header: string): "," | ";" {
  let commas = 0;
  let semicolons = 0;
  let quoted = false;
  for (const character of header) {
    if (character === '"') quoted = !quoted;
    if (!quoted && character === ",") commas += 1;
    if (!quoted && character === ";") semicolons += 1;
  }
  return semicolons > commas ? ";" : ",";
}

function parseRecords(input: string, delimiter: "," | ";") {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;

  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];
    const next = input[index + 1];
    if (character === '"') {
      if (quoted && next === '"') {
        cell += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && character === delimiter) {
      row.push(cell);
      cell = "";
    } else if (!quoted && (character === "\n" || character === "\r")) {
      if (character === "\r" && next === "\n") index += 1;
      row.push(cell);
      if (row.some((value) => value.trim() !== "")) rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += character;
    }
    if (cell.length > MAX_CELL_LENGTH) throw new Error("CSV_CELL_TOO_LARGE");
  }
  if (quoted) throw new Error("CSV_UNTERMINATED_QUOTE");
  row.push(cell);
  if (row.some((value) => value.trim() !== "")) rows.push(row);
  return rows;
}

function headerIndex(headers: string[]) {
  const normalized = headers.map(normalizeHeader);
  return (field: keyof SportlinkMember) => normalized.findIndex((header) => headerAliases[field].includes(header));
}

function parseActive(value: string) {
  const normalized = value.trim().toLowerCase();
  return ["ja", "yes", "true", "1", "actief"].includes(normalized);
}

export function previewSportlinkImport(input: string): ImportPreview {
  const byteLength = new TextEncoder().encode(input).byteLength;
  if (byteLength > SPORTLINK_MAX_BYTES) throw new Error("CSV_FILE_TOO_LARGE");
  if (input.charCodeAt(0) === 0xfeff) input = input.slice(1);

  const delimiter = detectDelimiter(input.split(/\r?\n/, 1)[0] ?? "");
  const records = parseRecords(input, delimiter);
  if (records.length < 2) throw new Error("CSV_HEADER_OR_ROWS_MISSING");
  if (records[0].length > MAX_COLUMNS) throw new Error("CSV_TOO_MANY_COLUMNS");
  if (records.length - 1 > MAX_ROWS) throw new Error("CSV_TOO_MANY_ROWS");

  const headers = records[0];
  const indexFor = headerIndex(headers);
  const required: (keyof SportlinkMember)[] = ["relationNumber", "firstName", "lastName", "email", "team", "activeForSeason"];
  const issues: ImportIssue[] = [];
  for (const field of required) {
    if (indexFor(field) === -1) issues.push({ row: 1, field, message: "Verplichte kolom ontbreekt." });
  }
  if (issues.length > 0) return { members: [], issues, summary: { total: records.length - 1, valid: 0, invalid: records.length - 1, duplicates: 0 }, delimiter };

  const members: SportlinkMember[] = [];
  const seenRelations = new Set<string>();
  let duplicates = 0;
  records.slice(1).forEach((record, offset) => {
    const rowNumber = offset + 2;
    const value = (field: keyof SportlinkMember) => record[indexFor(field)]?.trim() ?? "";
    const rawValues = record.filter((cell) => cell.trim() !== "");
    const formulaCell = rawValues.find((cell) => isFormulaLike(cell));
    if (formulaCell) {
      issues.push({ row: rowNumber, message: "Formuleachtige waarden zijn niet toegestaan." });
      return;
    }

    const candidate = {
      relationNumber: normalizeRelationNumber(value("relationNumber")),
      firstName: value("firstName"),
      insertion: value("insertion") || null,
      lastName: value("lastName"),
      email: normalizeEmail(value("email")),
      team: value("team"),
      activeForSeason: parseActive(value("activeForSeason")),
    };
    const parsed = memberSchema.safeParse(candidate);
    if (!parsed.success) {
      issues.push({ row: rowNumber, message: "Een of meer velden zijn ongeldig." });
      return;
    }
    if (seenRelations.has(parsed.data.relationNumber)) {
      duplicates += 1;
      issues.push({ row: rowNumber, field: "relationNumber", message: "Dubbel relatienummer in dit bestand." });
      return;
    }
    seenRelations.add(parsed.data.relationNumber);
    members.push(parsed.data);
  });

  return {
    members,
    issues,
    summary: { total: records.length - 1, valid: members.length, invalid: issues.length, duplicates },
    delimiter,
  };
}
