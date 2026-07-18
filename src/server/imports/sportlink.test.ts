import { describe, expect, it } from "vitest";
import { previewSportlinkImport } from "@/server/imports/sportlink";

describe("Sportlink CSV preview", () => {
  it("accepts semicolon CSV, normalizes relation numbers and e-mail", () => {
    const result = previewSportlinkImport([
      "Relatienummer;Voornaam;Achternaam;E-mailadres;Team;Actief voor seizoen",
      " dsv-42 ;Sophie;De Jong; SOPHIE@EXAMPLE.NL ;MO11-1;Ja",
    ].join("\n"));

    expect(result.delimiter).toBe(";");
    expect(result.summary).toMatchObject({ total: 1, valid: 1, invalid: 0 });
    expect(result.members[0]).toMatchObject({ relationNumber: "DSV-42", email: "sophie@example.nl", activeForSeason: true });
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

  it("requires the canonical member columns", () => {
    const result = previewSportlinkImport("Naam,Team\nSophie,MO11-1");
    expect(result.members).toHaveLength(0);
    expect(result.issues.map((issue) => issue.field)).toContain("relationNumber");
  });
});
