# Eerste opdracht voor Codex Desktop

Je bent de lead engineer en integrator voor het **Duindorp SV Tenueportaal**. Werk uitsluitend in de momenteel geopende repository `D:\\Codex\\repos\\duindorp-sv-tenueportaal`. De bovenliggende map `D:\\Codex\\repos` kan andere actieve repositories bevatten en mag niet als werkgebied worden behandeld. Deze repository bevat alleen projectinstructies, de bindende canon en ontwerpassets; de applicatiecode moet nog volledig worden aangemaakt.

## Hoofddoel

Bouw de volledige, werkende minimale MVP zoals bindend beschreven in:

- `AGENTS.md`
- `docs/canon/Duindorp_SV_Tenueportaal_MVP_Canon_v1.0.pdf`
- `docs/canon/MVP_CANON_TEXT.txt`
- `docs/design/APPROVED_MASTER_SHOWCASE.png`

Deze MVP wordt echt gebruikt. Scope, statussen, rollen, login, betalingen, QR en deel-leveringen mogen niet worden afgezwakt, vervangen of uitgebreid met niet-canonieke ideeën.

## Werkwijze

1. Lees eerst alle bovenstaande bronnen volledig.
2. Controleer de huidige projectmap en bevestig dat er nog geen appcode is. Inspecteer of wijzig geen sibling-repositories onder `D:\\Codex\\repos`.
3. Spawn parallelle subagents voor:
   - canon/scope en acceptatiecriteria;
   - architectuur en projectstructuur;
   - database/RLS/security;
   - design-systemanalyse op basis van de showcase;
   - teststrategie en lokale procesisolatie.
4. Laat deze subagents vooral analyseren en concrete voorstellen/risico's teruggeven. Wacht op hun resultaten.
5. Maak daarna als hoofdagent één geïntegreerd uitvoeringsplan in `docs/project/IMPLEMENTATION_PLAN.md`, met fasen, afhankelijkheden, quality gates en exact MVP-bereik.
6. Werk vervolgens autonoom door. Stop niet na alleen planning of scaffolding.

## Initialisatie in deze map

- Initialiseer git wanneer `.git` ontbreekt.
- Scaffold een actuele stabiele Next.js App Router-app met TypeScript en Tailwind **rechtstreeks in deze map**; maak geen geneste projectdirectory.
- Gebruik `pnpm` en projectlokale dependencies.
- Configureer shadcn/ui, Motion, Supabase, Zod, Vitest en Playwright.
- Maak een heldere modulaire-monolietstructuur voor backoffice, ledenportaal en uitgifte.
- Bewaar alle blijvende beslissingen en voortgang in `docs/project/`.

## Andere lokale processen beschermen

Controleer vóór het starten van webserver, Supabase, Docker of andere listeners welke poorten bezet zijn. Kies vrije project-specifieke poorten, leg die vast en dood nooit een bestaand proces. Gebruik een unieke Supabase project-id en lokale poortset. Raak geen andere repositories — met name sibling-mappen onder `D:\\Codex\\repos` — containers, volumes, globale instellingen of processen aan.

## Autonomie

Neem normale reversibele technische beslissingen zelf binnen canon en vaste stack. Vraag alleen bij een echte blocker of onomkeerbare externe actie. Wanneer Mollie- of SendGrid-credentials ontbreken, bouw je de volledige veilige adapter, sandbox/mockflow, env-validatie en tests en ga je verder met al het overige.

## Bouwverwachting

Werk fase voor fase door met implementatie, tests en bewijs. Gebruik subagents opnieuw voor onafhankelijke reviews en testtriage. De hoofdagent integreert altijd zelf en draait na iedere fase de volledige relevante gates.

Minimaal op te leveren:

- professioneel consistent Duindorp SV-designsysteem;
- complete backoffice voor leden, Sportlink-CSV, artikelen, bestellingen, handmatige betalingen, leveringen, e-mails en exports;
- ouderlogin met 6-cijferige code van 10 minuten, zonder wachtwoord/magic link/Supabase-ouderaccount;
- optionele expliciete toevoeging van meerdere leden op hetzelfde e-mailadres;
- één afzonderlijke exacte betaling en QR per lid;
- leden-dashboard met per lid één container en artikelregels `Nalevering`, `Af te halen`, `Afgehaald`;
- beperkte uitgifte-app met QR-scan, artikelkeuze en veilige deel-uitgifte;
- Mollie sandbox/webhook-first integratie en SendGrid-integratie;
- RLS, auditlog, rate limiting, veilige sessies en token hashing;
- migrations, seeddata, tests, E2E, documentatie en releasechecklist.

## Voortgangsrapportage

Werk `docs/project/PROGRESS.md`, `DECISIONS.md`, `RISKS.md` en `TEST_EVIDENCE.md` continu bij. Rapporteer pas dat een fase klaar is wanneer de gates groen zijn. Ga daarna zelfstandig naar de volgende fase, zolang er geen echte blocker bestaat.

Begin nu met lezen, subagents, preflight en vervolgens daadwerkelijke implementatie.
