export const DYNAMIC_IMPORT_LIMITS = {
  maxBytes: 10 * 1024 * 1024,
  maxRows: 10_000,
  maxColumns: 64,
  maxCellLength: 512,
  maxHeaderLength: 120,
  maxUniquePreviewValues: 100,
  parseTimeoutMs: 5_000,
} as const;

export type CsvDelimiter = "," | ";";

export type ParsedCsv = {
  delimiter: CsvDelimiter;
  headers: string[];
  records: string[][];
  rowShapeIssues: Array<{ row: number; actualColumns: number }>;
};

export type CsvColumnInspection = {
  index: number;
  label: string;
  uniqueValues: string[];
  uniqueValueCount: number;
  emptyCount: number;
  nonEmptyCount: number;
  valuesTruncated: boolean;
};

const unsafeHeaderFormat = /[\p{Cc}\p{Cf}\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u3164\uFE00-\uFE0F\uFFA0]/u;
const formulaPrefix = /^[=+\-@\t\r]/u;

function csvError(code: string): never {
  throw new Error(code);
}

function strictUtf8(bytes: Uint8Array) {
  if (bytes.byteLength === 0) csvError("CSV_EMPTY");
  if (bytes.byteLength > DYNAMIC_IMPORT_LIMITS.maxBytes) csvError("CSV_FILE_TOO_LARGE");
  if (
    (bytes[0] === 0xff && bytes[1] === 0xfe)
    || (bytes[0] === 0xfe && bytes[1] === 0xff)
  ) {
    csvError("CSV_UTF16_NOT_SUPPORTED");
  }
  let decoded: string;
  try {
    decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    csvError("CSV_UTF8_INVALID");
  }
  if (decoded.includes("\u0000")) csvError("CSV_BINARY_CONTENT");
  return decoded.charCodeAt(0) === 0xfeff ? decoded.slice(1) : decoded;
}

function delimiterFor(input: string): CsvDelimiter {
  let commas = 0;
  let semicolons = 0;
  let quoted = false;
  for (let index = 0; index < input.length; index += 1) {
    const character = input[index]!;
    const next = input[index + 1];
    if (character === "\"") {
      if (quoted && next === "\"") index += 1;
      else quoted = !quoted;
      continue;
    }
    if (!quoted && (character === "\n" || character === "\r")) break;
    if (!quoted && character === ",") commas += 1;
    if (!quoted && character === ";") semicolons += 1;
  }
  if (commas === 0 && semicolons === 0) csvError("CSV_DELIMITER_MISSING");
  return semicolons > commas ? ";" : ",";
}

function normalizedHeader(value: string) {
  const normalized = value.normalize("NFKC").trim().replace(/\s+/gu, " ");
  if (
    normalized.length === 0
    || normalized.length > DYNAMIC_IMPORT_LIMITS.maxHeaderLength
    || unsafeHeaderFormat.test(normalized)
    || formulaPrefix.test(normalized)
  ) {
    csvError("CSV_HEADER_INVALID");
  }
  return normalized;
}

export function parseCsvBytes(
  bytes: Uint8Array,
  monotonicNow: () => number = () => performance.now(),
): ParsedCsv {
  const input = strictUtf8(bytes);
  const delimiter = delimiterFor(input);
  const startedAt = monotonicNow();
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  let quoteClosed = false;

  function checkDeadline(index: number) {
    if ((index & 4095) === 0 && monotonicNow() - startedAt > DYNAMIC_IMPORT_LIMITS.parseTimeoutMs) {
      csvError("CSV_PARSE_TIMEOUT");
    }
  }

  function append(character: string) {
    cell += character;
    if (cell.length > DYNAMIC_IMPORT_LIMITS.maxCellLength) csvError("CSV_CELL_TOO_LARGE");
  }

  function finishCell() {
    row.push(cell);
    if (row.length > DYNAMIC_IMPORT_LIMITS.maxColumns) csvError("CSV_TOO_MANY_COLUMNS");
    cell = "";
    quoteClosed = false;
  }

  function finishRow() {
    finishCell();
    if (row.some((value) => value.trim() !== "")) {
      rows.push(row);
      if (rows.length > DYNAMIC_IMPORT_LIMITS.maxRows + 1) csvError("CSV_TOO_MANY_ROWS");
    }
    row = [];
  }

  for (let index = 0; index < input.length; index += 1) {
    checkDeadline(index);
    const character = input[index]!;
    const next = input[index + 1];

    if (quoted) {
      if (character === "\"" && next === "\"") {
        append("\"");
        index += 1;
      } else if (character === "\"") {
        quoted = false;
        quoteClosed = true;
      } else {
        append(character);
      }
      continue;
    }

    if (quoteClosed) {
      if (character === " " || character === "\t") continue;
      if (character === delimiter) {
        finishCell();
        continue;
      }
      if (character === "\n" || character === "\r") {
        if (character === "\r" && next === "\n") index += 1;
        finishRow();
        continue;
      }
      csvError("CSV_CHARACTERS_AFTER_QUOTE");
    }

    if (character === "\"") {
      if (cell.length > 0) csvError("CSV_QUOTE_INVALID");
      quoted = true;
    } else if (character === delimiter) {
      finishCell();
    } else if (character === "\n" || character === "\r") {
      if (character === "\r" && next === "\n") index += 1;
      finishRow();
    } else {
      append(character);
    }
  }

  if (quoted) csvError("CSV_UNTERMINATED_QUOTE");
  if (row.length > 0 || cell.length > 0 || quoteClosed) finishRow();
  if (rows.length < 2) csvError("CSV_HEADER_OR_ROWS_MISSING");

  const headers = rows[0]!.map(normalizedHeader);
  const normalized = headers.map((header) => header.toLocaleLowerCase("nl-NL"));
  if (new Set(normalized).size !== normalized.length) csvError("CSV_DUPLICATE_HEADERS");

  const records = rows.slice(1);
  const rowShapeIssues = records.flatMap((record, index) => (
    record.length === headers.length
      ? []
      : [{ row: index + 2, actualColumns: record.length }]
  ));
  return { delimiter, headers, records, rowShapeIssues };
}

export function inspectCsvColumns(parsed: ParsedCsv): CsvColumnInspection[] {
  return parsed.headers.map((label, index) => {
    const unique = new Set<string>();
    let emptyCount = 0;
    let nonEmptyCount = 0;
    for (const record of parsed.records) {
      const value = record[index]?.trim() ?? "";
      if (!value) {
        emptyCount += 1;
      } else {
        nonEmptyCount += 1;
        if (unique.size < DYNAMIC_IMPORT_LIMITS.maxUniquePreviewValues) unique.add(value);
      }
    }
    const allUnique = new Set(
      parsed.records
        .map((record) => record[index]?.trim() ?? "")
        .filter(Boolean),
    );
    return {
      index,
      label,
      uniqueValues: [...unique],
      uniqueValueCount: allUnique.size,
      emptyCount,
      nonEmptyCount,
      valuesTruncated: allUnique.size > DYNAMIC_IMPORT_LIMITS.maxUniquePreviewValues,
    };
  });
}
