import { describe, expect, it } from "vitest";
import {
  DYNAMIC_IMPORT_LIMITS,
  inspectCsvColumns,
  parseCsvBytes,
} from "@/server/imports/csv-parser";

const bytes = (value: string) => new TextEncoder().encode(value);

describe("dynamische CSV-parser", () => {
  it("leest UTF-8 met BOM, puntkomma, quotes en ingebedde regels", () => {
    const parsed = parseCsvBytes(bytes([
      "\uFEFFRelatienummer;Voornaam;Notitie",
      "DSV-1;Noa;\"regel 1",
      "regel 2\"",
    ].join("\r\n")));
    expect(parsed).toMatchObject({
      delimiter: ";",
      headers: ["Relatienummer", "Voornaam", "Notitie"],
      records: [["DSV-1", "Noa", "regel 1\r\nregel 2"]],
      rowShapeIssues: [],
    });
  });

  it("weigert invalid UTF-8, UTF-16 en binaire NUL", () => {
    expect(() => parseCsvBytes(Uint8Array.from([0xc3, 0x28]))).toThrow("CSV_UTF8_INVALID");
    expect(() => parseCsvBytes(Uint8Array.from([0xff, 0xfe, 0x41, 0x00]))).toThrow("CSV_UTF16_NOT_SUPPORTED");
    expect(() => parseCsvBytes(bytes("A,B\nx,\u0000"))).toThrow("CSV_BINARY_CONTENT");
  });

  it("blokkeert duplicate headers na veilige Unicode-normalisatie", () => {
    expect(() => parseCsvBytes(bytes("Maat Broek,ｍａａｔ   broek\n152,164"))).toThrow("CSV_DUPLICATE_HEADERS");
    expect(() => parseCsvBytes(bytes("=CMD,Team\nx,y"))).toThrow("CSV_HEADER_INVALID");
  });

  it("handhaaft rij-, kolom-, cel-, byte- en tijdlimieten tijdens parsing", () => {
    expect(() => parseCsvBytes(bytes(`A,B\n${"x".repeat(DYNAMIC_IMPORT_LIMITS.maxCellLength + 1)},y`))).toThrow("CSV_CELL_TOO_LARGE");
    expect(() => parseCsvBytes(bytes(`${Array.from({ length: DYNAMIC_IMPORT_LIMITS.maxColumns + 1 }, (_, index) => `H${index}`).join(",")}\nwaarde`))).toThrow("CSV_TOO_MANY_COLUMNS");
    expect(() => parseCsvBytes(new Uint8Array(DYNAMIC_IMPORT_LIMITS.maxBytes + 1))).toThrow("CSV_FILE_TOO_LARGE");
    let clock = 0;
    const slowCsv = `A,B\n${Array.from({ length: 12 }, () => `${"x".repeat(400)},y`).join("\n")}`;
    expect(() => parseCsvBytes(bytes(slowCsv), () => {
      clock += 3_000;
      return clock;
    })).toThrow("CSV_PARSE_TIMEOUT");
  });

  it("meldt afwijkende rijbreedte zonder bronwaarden duurzaam te hoeven bewaren", () => {
    const parsed = parseCsvBytes(bytes("A,B,C\n1,2,3\n4,5"));
    expect(parsed.rowShapeIssues).toEqual([{ row: 3, actualColumns: 2 }]);
  });

  it("maakt per kolom begrensde unieke bronwaardestatistiek", () => {
    const parsed = parseCsvBytes(bytes("Maat Broek,Team\n152,JO11-1\n,JO11-1\n164,JO13-2"));
    expect(inspectCsvColumns(parsed)).toEqual([
      {
        index: 0,
        label: "Maat Broek",
        uniqueValues: ["152", "164"],
        uniqueValueCount: 2,
        emptyCount: 1,
        nonEmptyCount: 2,
        valuesTruncated: false,
      },
      expect.objectContaining({ label: "Team", uniqueValueCount: 2, emptyCount: 0 }),
    ]);
  });

  it("weigert ongeldige quoteconstructies en ontbrekende data", () => {
    expect(() => parseCsvBytes(bytes("A,B\n\"open,x"))).toThrow("CSV_UNTERMINATED_QUOTE");
    expect(() => parseCsvBytes(bytes("A,B\n\"x\"rest,y"))).toThrow("CSV_CHARACTERS_AFTER_QUOTE");
    expect(() => parseCsvBytes(bytes("A,B"))).toThrow("CSV_HEADER_OR_ROWS_MISSING");
  });
});
