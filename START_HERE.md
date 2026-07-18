# Duindorp SV Tenueportaal — starten in Codex Desktop

Deze starter is bedoeld voor een nieuwe lokale repository onder:

`D:\Codex\repos\duindorp-sv-tenueportaal`

De map bevat bewust nog **geen gegenereerde applicatiecode**. Codex Desktop initialiseert en bouwt de volledige applicatie rechtstreeks in deze projectmap.

## Eenmalige installatie

1. Pak dit ZIP-bestand uit in:
   `D:\Codex\repos`
2. Na uitpakken moet deze map bestaan:
   `D:\Codex\repos\duindorp-sv-tenueportaal`
3. Open in Codex Desktop **alleen** deze projectmap:
   `D:\Codex\repos\duindorp-sv-tenueportaal`
4. Open `MASTER_BUILD_PROMPT.md`.
5. Kopieer de volledige inhoud naar één nieuw hoofdgesprek in Codex Desktop.
6. Laat Codex autonoom uitvoeren en beantwoord alleen vragen die volgens `AGENTS.md` echte blockers zijn.

## Niet doen

- Open niet de bovenliggende map `D:\Codex\repos` als project. Daar kunnen andere repositories staan.
- Laat Codex geen extra geneste appmap maken.
- Laat Codex geen processen, containers, databases of bestanden van andere projecten aanpassen of stoppen.
- Gebruik geen verzonnen `pnpm codex:*`-commando's. Codex Desktop beheert gesprekken, subagents, diffs en worktrees zelf.

## Bindende bestanden

- `AGENTS.md` — permanente bouw-, veiligheids- en autonomieregels.
- `docs/canon/Duindorp_SV_Tenueportaal_MVP_Canon_v1.0.pdf` — bindende product-, technische en designcanon.
- `docs/canon/MVP_CANON_TEXT.txt` — doorzoekbare tekstversie van de canon.
- `docs/design/APPROVED_MASTER_SHOWCASE.png` — bindende visuele richting.
- `docs/design/DUINDORP_SV_LOGO.png` — origineel clublogo.

## Na de eerste run

Gebruik bij voorkeur één Codex Desktop-hoofdgesprek per coherente bouwfase. Laat iedere hoofdagent eerst deze bestanden lezen en bijwerken:

- `docs/project/PROGRESS.md`
- `docs/project/DECISIONS.md`
- `docs/project/RISKS.md`
- `docs/project/TEST_EVIDENCE.md`

De applicatie, Git-repository, lokale Supabase-configuratie en alle projectbestanden blijven binnen `D:\Codex\repos\duindorp-sv-tenueportaal`.
