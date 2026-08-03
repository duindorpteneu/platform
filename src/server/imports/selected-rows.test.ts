import { describe, expect, it, vi } from "vitest";
import type { ParsedCsv } from "@/server/imports/csv-parser";
import { sha256Hex } from "@/server/imports/mapping";
import {
  assertStoredMappingHeaders,
  buildSelectedImportRows,
  selectedRowIdentityKey,
} from "@/server/imports/selected-rows";
import type { StoredImportMappingEntry } from "@/lib/import-contract";

function fixture(): { parsed: ParsedCsv; mapping: StoredImportMappingEntry[] } {
  const headers = ["Relatienummer", "Voornaam", "Geboortedatum", "Geslacht", "Actief", "Maat Broek", "Niet gekozen"];
  return {
    parsed: {
      delimiter: ";",
      headers,
      records: [
        [" ab-12 ", " Noa  ", "31/01/2014", "meisje", "ja", " maat 152 ", "=geheim"],
        ["", "=FORMULE", "31-02-2014", "onbekende waarde", "misschien", "XXXL", "privé"],
      ],
      rowShapeIssues: [],
    },
    mapping: [
      {
        columnIndex: 0,
        sourceHeaderHash: sha256Hex(headers[0]!),
        target: { kind: "member_field", field: "external_member_id" },
      },
      {
        columnIndex: 1,
        sourceHeaderHash: sha256Hex(headers[1]!),
        target: { kind: "member_field", field: "first_name" },
      },
      {
        columnIndex: 2,
        sourceHeaderHash: sha256Hex(headers[2]!),
        target: { kind: "member_field", field: "date_of_birth" },
      },
      {
        columnIndex: 3,
        sourceHeaderHash: sha256Hex(headers[3]!),
        target: { kind: "member_field", field: "gender" },
      },
      {
        columnIndex: 4,
        sourceHeaderHash: sha256Hex(headers[4]!),
        target: { kind: "member_field", field: "active_for_season" },
      },
      {
        columnIndex: 5,
        sourceHeaderHash: sha256Hex(headers[5]!),
        target: { kind: "product_size", articleId: "c2000000-0000-4000-8000-000000000001" },
      },
    ],
  };
}

describe("selected dynamic-import rows", () => {
  it("copies only selected targets and canonicalizes DOB, gender and booleans", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-03T00:00:00Z"));
    const { parsed, mapping } = fixture();
    const [row] = buildSelectedImportRows({ parsed, mapping, startSourceRow: 2, limit: 1 });
    expect(row).toEqual({
      sourceRow: 2,
      fields: {
        external_member_id: "AB-12",
        first_name: "Noa",
        date_of_birth: "2014-01-31",
        gender: "female",
        active_for_season: true,
      },
      sizes: { "c2000000-0000-4000-8000-000000000001": "maat 152" },
      errors: [],
    });
    expect(JSON.stringify(row)).not.toContain("geheim");
    vi.useRealTimers();
  });

  it("records safe error codes and preserves an unknown but safe size", () => {
    const { parsed, mapping } = fixture();
    const [row] = buildSelectedImportRows({ parsed, mapping, startSourceRow: 3, limit: 1 });
    expect(row?.sizes).toEqual({ "c2000000-0000-4000-8000-000000000001": "XXXL" });
    expect(row?.errors).toEqual([
      "invalid_active_for_season",
      "invalid_date_of_birth",
      "invalid_first_name",
      "invalid_gender",
    ]);
    expect(JSON.stringify(row)).not.toContain("privé");
  });

  it("marks every ragged CSV record as a blocking dry-run row", () => {
    const { parsed, mapping } = fixture();
    parsed.rowShapeIssues = [{ row: 2, actualColumns: 4 }];
    const [row] = buildSelectedImportRows({ parsed, mapping, startSourceRow: 2, limit: 1 });
    expect(row?.errors).toContain("invalid_row_shape");
  });

  it("binds every selected column to the exact uploaded header", () => {
    const { parsed, mapping } = fixture();
    expect(() => assertStoredMappingHeaders(mapping, parsed)).not.toThrow();
    parsed.headers[0] = "Ander relatienummer";
    expect(() => assertStoredMappingHeaders(mapping, parsed)).toThrow("DYNAMIC_IMPORT_HEADER_CHANGED");
  });

  it("derives a stable exact identity key without fuzzy matching", () => {
    expect(selectedRowIdentityKey({
      sourceRow: 2,
      fields: { first_name: "Noa", last_name: "Jansen", email: "ouder@example.test" },
      sizes: {},
      errors: [],
    })).toBe("compound:NOA JANSEN:ouder@example.test:");
    expect(selectedRowIdentityKey({
      sourceRow: 3,
      fields: { first_name: "Noa", last_name: "Jansen" },
      sizes: {},
      errors: [],
    })).toBeNull();
    expect(selectedRowIdentityKey({
      sourceRow: 4,
      fields: {
        first_name: "Noa",
        last_name: "Jansen",
        email: "eerste@example.test",
        date_of_birth: "2014-01-31",
      },
      sizes: {},
      errors: [],
    })).toBe("compound:NOA JANSEN::2014-01-31");
    expect(selectedRowIdentityKey({
      sourceRow: 5,
      fields: {
        first_name: "Noa",
        last_name: "Jansen",
        email: "tweede@example.test",
        date_of_birth: "2014-01-31",
      },
      sizes: {},
      errors: [],
    })).toBe("compound:NOA JANSEN::2014-01-31");
  });
});
