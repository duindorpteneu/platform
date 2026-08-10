import type { StoredImportMappingEntry } from "@/lib/import-contract";
import type { ParsedCsv } from "@/server/imports/csv-parser";
import { normalizeImportSize, sha256Hex } from "@/server/imports/mapping";

export type SelectedImportRow = {
  sourceRow: number;
  fields: Record<string, string | boolean>;
  sizes: Record<string, string>;
  errors: string[];
};

const unsafeValueFormat =
  /[\p{Cc}\p{Cf}\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u3164\uFE00-\uFE0F\uFFA0]/u;
const formulaPrefix = /^[=+\-@\t\r]/u;

function normalizedText(value: string) {
  return value.normalize("NFKC").trim().replace(/\s+/gu, " ");
}

function safeText(value: string, maximumLength: number) {
  const normalized = normalizedText(value);
  if (!normalized) return { kind: "empty" as const };
  if (
    normalized.length > maximumLength
    || unsafeValueFormat.test(normalized)
    || formulaPrefix.test(normalized)
  ) {
    return { kind: "invalid" as const };
  }
  return { kind: "value" as const, value: normalized };
}

function parseDateOfBirth(value: string) {
  const normalized = normalizedText(value);
  if (!normalized) return { kind: "empty" as const };
  let year: number;
  let month: number;
  let day: number;
  let match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(normalized);
  if (match) {
    year = Number(match[1]);
    month = Number(match[2]);
    day = Number(match[3]);
  } else {
    match = /^(\d{2})[-/](\d{2})[-/](\d{4})$/u.exec(normalized);
    if (!match) return { kind: "invalid" as const };
    day = Number(match[1]);
    month = Number(match[2]);
    year = Number(match[3]);
  }
  const candidate = new Date(Date.UTC(year, month - 1, day));
  if (
    candidate.getUTCFullYear() !== year
    || candidate.getUTCMonth() !== month - 1
    || candidate.getUTCDate() !== day
    || year < 1900
  ) {
    return { kind: "invalid" as const };
  }
  const iso = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  if (iso > new Date().toISOString().slice(0, 10)) return { kind: "invalid" as const };
  return { kind: "value" as const, value: iso };
}

function parseGender(value: string) {
  const normalized = normalizedText(value).toLocaleLowerCase("nl-NL");
  if (!normalized) return { kind: "empty" as const };
  const aliases: Record<string, "male" | "female" | "other" | "unknown"> = {
    m: "male",
    man: "male",
    jongen: "male",
    male: "male",
    v: "female",
    vrouw: "female",
    meisje: "female",
    female: "female",
    x: "other",
    anders: "other",
    nonbinair: "other",
    "non-binair": "other",
    other: "other",
    onbekend: "unknown",
    unknown: "unknown",
  };
  const parsed = aliases[normalized];
  return parsed
    ? { kind: "value" as const, value: parsed }
    : { kind: "invalid" as const };
}

function parseActive(value: string) {
  const normalized = normalizedText(value).toLocaleLowerCase("nl-NL");
  if (!normalized) return { kind: "empty" as const };
  if (["1", "ja", "j", "true", "actief"].includes(normalized)) {
    return { kind: "value" as const, value: true };
  }
  if (["0", "nee", "n", "false", "inactief"].includes(normalized)) {
    return { kind: "value" as const, value: false };
  }
  return { kind: "invalid" as const };
}

function fieldValue(field: string, rawValue: string) {
  if (field === "date_of_birth") return parseDateOfBirth(rawValue);
  if (field === "gender") return parseGender(rawValue);
  if (field === "active_for_season") return parseActive(rawValue);

  const maximumLength = field === "email"
    ? 320
    : field === "insertion"
      ? 80
      : 120;
  const result = safeText(rawValue, maximumLength);
  if (result.kind !== "value") return result;
  if (field === "email") {
    return { kind: "value" as const, value: result.value.toLocaleLowerCase("nl-NL") };
  }
  if (field === "external_member_id") {
    return { kind: "value" as const, value: result.value.toLocaleUpperCase("nl-NL") };
  }
  return result;
}

export function assertStoredMappingHeaders(
  mapping: readonly StoredImportMappingEntry[],
  parsed: ParsedCsv,
) {
  for (const entry of mapping) {
    const header = parsed.headers[entry.columnIndex];
    if (header === undefined || sha256Hex(header) !== entry.sourceHeaderHash) {
      throw new Error("DYNAMIC_IMPORT_HEADER_CHANGED");
    }
  }
}

export function buildSelectedImportRows(input: {
  parsed: ParsedCsv;
  mapping: readonly StoredImportMappingEntry[];
  startSourceRow: number;
  limit: number;
}) {
  const { parsed, mapping, startSourceRow, limit } = input;
  if (
    !Number.isInteger(startSourceRow)
    || startSourceRow < 2
    || !Number.isInteger(limit)
    || limit < 1
    || limit > 1_000
  ) {
    throw new Error("DYNAMIC_IMPORT_ROW_WINDOW_INVALID");
  }
  assertStoredMappingHeaders(mapping, parsed);
  const startIndex = startSourceRow - 2;
  if (startIndex > parsed.records.length) throw new Error("DYNAMIC_IMPORT_ROW_WINDOW_INVALID");
  const invalidShapeRows = new Set(parsed.rowShapeIssues.map((issue) => issue.row));

  return parsed.records.slice(startIndex, startIndex + limit).map((record, offset) => {
    const fields: Record<string, string | boolean> = {};
    const sizes: Record<string, string> = {};
    const errors = new Set<string>();
    const sourceRow = startSourceRow + offset;
    if (invalidShapeRows.has(sourceRow)) errors.add("invalid_row_shape");

    for (const entry of mapping) {
      const rawValue = record[entry.columnIndex] ?? "";
      if (entry.target.kind === "member_field") {
        const parsedValue = fieldValue(entry.target.field, rawValue);
        if (parsedValue.kind === "value") fields[entry.target.field] = parsedValue.value;
        else if (parsedValue.kind === "invalid") errors.add(`invalid_${entry.target.field}`);
        continue;
      }

      const size = safeText(rawValue, 160);
      if (size.kind === "value") {
        sizes[entry.target.articleId] = size.value;
      } else if (size.kind === "invalid") {
        errors.add(`invalid_size_${sha256Hex(entry.target.articleId).slice(0, 16)}`);
      }
    }

    return {
      sourceRow,
      fields,
      sizes,
      errors: [...errors].sort(),
    } satisfies SelectedImportRow;
  });
}

export function selectedRowIdentityKey(row: SelectedImportRow) {
  const externalId = typeof row.fields.external_member_id === "string"
    ? row.fields.external_member_id
    : "";
  if (externalId) return `external:${externalId}`;
  const firstName = typeof row.fields.first_name === "string" ? row.fields.first_name : "";
  const insertion = typeof row.fields.insertion === "string" ? row.fields.insertion : "";
  const lastName = typeof row.fields.last_name === "string" ? row.fields.last_name : "";
  const email = typeof row.fields.email === "string" ? row.fields.email : "";
  const dateOfBirth = typeof row.fields.date_of_birth === "string"
    ? row.fields.date_of_birth
    : "";
  if (!firstName || !lastName || (!email && !dateOfBirth)) return null;
  return dateOfBirth
    ? `compound:${normalizeImportSize([firstName, insertion, lastName].join(" "))}::${dateOfBirth}`
    : `compound:${normalizeImportSize([firstName, insertion, lastName].join(" "))}:${email}:`;
}
