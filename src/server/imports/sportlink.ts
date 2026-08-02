import { z } from "zod";

export const SPORTLINK_MAX_BYTES = 10 * 1024 * 1024;
export const SPORTLINK_MAX_REQUEST_BYTES = SPORTLINK_MAX_BYTES;
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
export type SportlinkColumnMapping = Record<keyof SportlinkMember, string | null>;
export type SportlinkDatabaseRow = {
  relation_number: string;
  first_name: string;
  insertion: string | null;
  last_name: string;
  email: string;
  team: string;
  active_for_season: boolean;
};
export type ImportIssue = { row: number; field?: string; message: string };
export type ImportWarning = { field: keyof SportlinkMember; count: number; message: string };
export type ImportPreview = {
  members: SportlinkMember[];
  issues: ImportIssue[];
  warnings: ImportWarning[];
  summary: { total: number; valid: number; invalid: number; duplicates: number };
  delimiter: "," | ";";
  mapping: SportlinkColumnMapping;
};

export const SPORTLINK_CSV_MIME_TYPES = ["text/csv", "application/csv", "application/vnd.ms-excel"] as const;
const csvMimeTypes = new Set<string>(SPORTLINK_CSV_MIME_TYPES);

export function validateSportlinkUpload(file: Pick<File, "name" | "type" | "size">) {
  if (!file.name.toLocaleLowerCase("nl-NL").endsWith(".csv")) throw new Error("CSV_EXTENSION_INVALID");
  if (!csvMimeTypes.has(file.type.toLocaleLowerCase("en-US"))) throw new Error("CSV_MIME_INVALID");
  if (file.size > SPORTLINK_MAX_BYTES) throw new Error("CSV_FILE_TOO_LARGE");
}

export function sportlinkUploadMetadata(headers: Pick<Headers, "get">, size: number) {
  const encodedFileName = headers.get("x-duindorp-file-name");
  if (!encodedFileName || encodedFileName.length > 1_024) throw new Error("CSV_FILE_NAME_INVALID");
  let name: string;
  try {
    name = decodeURIComponent(encodedFileName);
  } catch {
    throw new Error("CSV_FILE_NAME_INVALID");
  }
  const type = headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  const metadata = { name, type, size };
  validateSportlinkUpload(metadata);
  return metadata;
}

export function normalizeSportlinkFileName(fileName: string) {
  let normalized = fileName.normalize("NFKC").replace(/[\u0000-\u001f\u007f]/g, "").trim();
  normalized = normalized.replace(/[^\p{L}\p{N} ._()-]/gu, "_").slice(0, 255).trim();
  if (!normalized.toLocaleLowerCase("nl-NL").endsWith(".csv")) return "sportlink.csv";
  return isFormulaLike(normalized) ? `_${normalized}` : normalized;
}

const headerAliases: Record<keyof SportlinkMember, string[]> = {
  relationNumber: ["relatienummer", "relatienr", "relatie nr", "relatiecode", "rel. code", "rel code"],
  firstName: ["voornaam", "roepnaam", "first name"],
  insertion: ["tussenvoegsel", "insertion"],
  lastName: ["achternaam", "last name"],
  email: ["e-mailadres", "emailadres", "e-mail", "email"],
  team: ["team", "teamnaam", "team naam", "lokale teams", "lokaal team"],
  activeForSeason: ["actief voor seizoen", "actief", "active for season"],
};

export function toSportlinkDatabaseRows(members: SportlinkMember[]): SportlinkDatabaseRow[] {
  return members.map((member) => ({
    relation_number: member.relationNumber,
    first_name: member.firstName,
    insertion: member.insertion,
    last_name: member.lastName,
    email: member.email,
    team: member.team,
    active_for_season: member.activeForSeason,
  }));
}

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
  return (field: keyof SportlinkMember) => {
    for (const alias of headerAliases[field]) {
      const index = normalized.indexOf(alias);
      if (index >= 0) return index;
    }
    return -1;
  };
}

function indexForAliases(headers: string[], aliases: string[]) {
  const normalized = headers.map(normalizeHeader);
  for (const alias of aliases) {
    const index = normalized.indexOf(alias);
    if (index >= 0) return index;
  }
  return -1;
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
  const mapping = Object.fromEntries(
    (Object.keys(headerAliases) as Array<keyof SportlinkMember>).map((field) => {
      const index = indexFor(field);
      return [field, index >= 0 ? headers[index].trim() : null];
    }),
  ) as SportlinkColumnMapping;
  const required: (keyof SportlinkMember)[] = ["relationNumber", "firstName", "lastName", "email", "team"];
  const issues: ImportIssue[] = [];
  const warnings: ImportWarning[] = [];
  for (const field of required) {
    if (indexFor(field) === -1) issues.push({ row: 1, field, message: "Verplichte kolom ontbreekt." });
  }
  if (issues.length > 0) return { members: [], issues, warnings, summary: { total: records.length - 1, valid: 0, invalid: records.length - 1, duplicates: 0 }, delimiter, mapping };

  const members: SportlinkMember[] = [];
  const seenRelations = new Set<string>();
  const initialsIndex = indexForAliases(headers, ["voorletter(s)", "voorletters", "initialen"]);
  let defaultedFirstNames = 0;
  let defaultedTeams = 0;
  let duplicates = 0;
  records.slice(1).forEach((record, offset) => {
    const rowNumber = offset + 2;
    const value = (field: keyof SportlinkMember) => record[indexFor(field)]?.trim() ?? "";
    const firstName = value("firstName") || record[initialsIndex]?.trim() || "";
    const team = value("team") || "Niet ingedeeld";
    const activeForSeason = indexFor("activeForSeason") === -1 ? true : parseActive(value("activeForSeason"));
    const importedValues = [value("relationNumber"), firstName, value("insertion"), value("lastName"), value("email"), team, value("activeForSeason")];
    const formulaCell = importedValues.find((cell) => isFormulaLike(cell));
    if (formulaCell) {
      issues.push({ row: rowNumber, message: "Formuleachtige waarden zijn niet toegestaan." });
      return;
    }

    if (!value("firstName") && firstName) defaultedFirstNames += 1;
    if (!value("team")) defaultedTeams += 1;

    const candidate = {
      relationNumber: normalizeRelationNumber(value("relationNumber")),
      firstName,
      insertion: value("insertion") || null,
      lastName: value("lastName"),
      email: normalizeEmail(value("email")),
      team,
      activeForSeason,
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

  if (indexFor("activeForSeason") === -1) {
    warnings.push({ field: "activeForSeason", count: records.length - 1, message: "Geen seizoenstatuskolom gevonden; de leden worden als actief voor het seizoen verwerkt." });
  }
  if (defaultedTeams > 0) {
    warnings.push({ field: "team", count: defaultedTeams, message: "Lege lokale teams worden als ‘Niet ingedeeld’ verwerkt." });
  }
  if (defaultedFirstNames > 0) {
    warnings.push({ field: "firstName", count: defaultedFirstNames, message: "Een ontbrekende roepnaam is aangevuld met de voorletters uit Sportlink." });
  }

  return {
    members,
    issues,
    warnings,
    summary: { total: records.length - 1, valid: members.length, invalid: issues.length, duplicates },
    delimiter,
    mapping,
  };
}
