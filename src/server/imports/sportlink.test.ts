import { describe, expect, it } from "vitest";
import { normalizeSportlinkFileName, previewSportlinkImport, toSportlinkDatabaseRows, validateSportlinkUpload } from "@/server/imports/sportlink";

describe("Sportlink CSV preview", () => {
  it("accepts alleen een CSV-extensie en geallowliste MIME", () => {
    expect(() => validateSportlinkUpload(new File(["a;b"], "leden.csv", { type: "text/csv" }))).not.toThrow();
    expect(() => validateSportlinkUpload(new File(["a;b"], "leden.txt", { type: "text/csv" }))).toThrow("CSV_EXTENSION_INVALID");
    expect(() => validateSportlinkUpload(new File(["a;b"], "leden.csv", { type: "application/octet-stream" }))).toThrow("CSV_MIME_INVALID");
  });

  it("bewaart een veilige herkenbare bronbestandsnaam", () => {
    expect(normalizeSportlinkFileName("Leden 528 personen gevonden.csv")).toBe("Leden 528 personen gevonden.csv");
    expect(normalizeSportlinkFileName("=leden<script>.csv")).toBe("_leden_script_.csv");
    expect(normalizeSportlinkFileName("leden.txt")).toBe("sportlink.csv");
  });
  it("accepts semicolon CSV, normalizes relation numbers and e-mail", () => {
    const result = previewSportlinkImport([
      "Relatienummer;Voornaam;Achternaam;E-mailadres;Team;Actief voor seizoen",
      " dsv-42 ;Sophie;De Jong; SOPHIE@EXAMPLE.NL ;MO11-1;Ja",
    ].join("\n"));

    expect(result.delimiter).toBe(";");
    expect(result.mapping).toMatchObject({ relationNumber: "Relatienummer", activeForSeason: "Actief voor seizoen" });
    expect(result.summary).toMatchObject({ total: 1, valid: 1, invalid: 0 });
    expect(result.members[0]).toMatchObject({ relationNumber: "DSV-42", email: "sophie@example.nl", activeForSeason: true });
    expect(result.warnings).toHaveLength(0);
    expect(toSportlinkDatabaseRows(result.members)[0]).toMatchObject({ relation_number: "DSV-42", first_name: "Sophie", active_for_season: true });
  });

  it("accepts the real Sportlink member-export columns with explicit safe fallbacks", () => {
    const result = previewSportlinkImport([
      "Naam;Roepnaam;Voorletter(s);Achternaam;Rel. code;E-mailadres;Mobiel nummer;Lokale teams",
      "Tester, Sophie;Sophie;S.;Tester; dsv-42 ; SOPHIE@EXAMPLE.NL ;+31612345678;JO13-1",
      "Voorbeeld, N.; ;N.;Voorbeeld;DSV-43;voorbeeld@example.nl;+31687654321;",
    ].join("\n"));

    expect(result.mapping).toMatchObject({ relationNumber: "Rel. code", firstName: "Roepnaam", team: "Lokale teams", activeForSeason: null });
    expect(result.summary).toEqual({ total: 2, valid: 2, invalid: 0, duplicates: 0 });
    expect(result.members).toEqual([
      expect.objectContaining({ relationNumber: "DSV-42", firstName: "Sophie", team: "JO13-1", activeForSeason: true }),
      expect.objectContaining({ relationNumber: "DSV-43", firstName: "N.", team: "Niet ingedeeld", activeForSeason: true }),
    ]);
    expect(result.warnings).toEqual([
      expect.objectContaining({ field: "activeForSeason", count: 2 }),
      expect.objectContaining({ field: "team", count: 1 }),
      expect.objectContaining({ field: "firstName", count: 1 }),
    ]);
  });

  it("reports duplicate relation numbers and blocks formula-like cells", () => {
    const result = previewSportlinkImport([
      "Relatienummer,Voornaam,Achternaam,E-mailadres,Team,Actief",
      "DSV-1,Noa,Jansen,noa@example.nl,JO13-1,Ja",
      "DSV-1,=Milan,Bakker,milan@example.nl,JO13-1,Ja",
    ].join("\n"));

    expect(result.members).toHaveLength(1);
    expect(result.summary.duplicates).toBe(0);
    expect(result.issues).toHaveLength(1);
    expect(result.issues[0].message).toContain("Formuleachtige");
  });

  it("negeert formuleachtige waarden in niet-geïmporteerde Sportlink-kolommen", () => {
    const result = previewSportlinkImport([
      "Relatienummer;Voornaam;Achternaam;E-mailadres;Team;Actief;Telefoonnummer",
      "DSV-1;Noa;Jansen;noa@example.nl;JO13-1;Ja;+31701234567",
    ].join("\n"));

    expect(result.summary).toMatchObject({ valid: 1, invalid: 0 });
  });

  it("requires the canonical member columns", () => {
    const result = previewSportlinkImport("Naam,Team\nSophie,MO11-1");
    expect(result.members).toHaveLength(0);
    expect(result.issues.map((issue) => issue.field)).toContain("relationNumber");
  });
});
