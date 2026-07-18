# AGENTS.md — Duindorp SV Tenueportaal

## 1. Opdracht

Bouw en lever de werkende minimale MVP van het **Duindorp SV Tenueportaal** in deze repository. Dit is geen prototype en geen vrijblijvende demo. Het wordt daadwerkelijk gebruikt door Duindorp SV voor leden, betalingen, deel-leveringen en uitgifte van tenues.

De bindende bronnen zijn, in deze volgorde:

1. `docs/canon/Duindorp_SV_Tenueportaal_MVP_Canon_v1.0.pdf`
2. `docs/canon/MVP_CANON_TEXT.txt`
3. `docs/design/APPROVED_MASTER_SHOWCASE.png`
4. deze `AGENTS.md`
5. overige documenten in `docs/project/`

Bij twijfel geldt de strengste interpretatie die de MVP klein, veilig, controleerbaar en canoniek houdt. Verzin geen functionaliteit. Leg een echte canononduidelijkheid vast in `docs/project/DECISIONS.md` en vraag alleen wanneer de keuze niet veilig en niet omkeerbaar is.

## 2. Niet-onderhandelbare MVP

- Eén Duindorp SV-product; geen multi-tenant SaaS en geen generieke clubbranding.
- Eén Next.js-applicatie met drie oppervlakken: backoffice, ledenportaal en uitgifte.
- Exact drie personeelsrollen: `beheerder`, `kledingcommissie`, `uitgifte`.
- Ouderlogin via e-mailadres en zescijferige verificatiecode, tien minuten geldig.
- Geen wachtwoord, geen magic link en geen Supabase Auth-account voor ouders.
- Medewerkers mogen wel via Supabase Auth worden beveiligd.
- Een ouder kan optioneel meerdere leden met hetzelfde e-mailadres toevoegen; nooit automatisch en nooit verplicht.
- Elk lid heeft een eigen bestelling, exact verschuldigd bedrag, betaalstatus, QR-code en artikelregels.
- Geen gezinsbetaling, deelbetaling of door ouder ingevoerd bedrag.
- Kas en pin worden handmatig per lid voor exact het verschuldigde bedrag geregistreerd.
- Mollie is webhook-first, server-side gevalideerd, idempotent en altijd per lid/bestelling.
- Elke artikelregel heeft zelfstandig een status: minimaal nalevering, af te halen en afgehaald in de leden-UI.
- Dezelfde QR-code per lid en seizoen ondersteunt meerdere uitgiftemomenten.
- Uitgifte kan alleen werkelijk beschikbare en betaalde/vrijgestelde artikelregels voltooien.
- Sportlink-leden worden via CSV geïmporteerd.
- SendGrid verzorgt transactionele en bulk-e-mail met templates en shortcodes.
- Alle gevoelige mutaties zijn geautoriseerd, server-side gevalideerd en auditbaar.

## 3. Vaste stack

- Next.js App Router, TypeScript en React Server Components waar passend.
- Tailwind CSS en shadcn/ui.
- Motion voor subtiele, functionele interacties; geen overmatige animatie.
- Supabase PostgreSQL, Storage en RLS.
- Supabase Auth uitsluitend voor medewerkers, tenzij de canon later expliciet wijzigt.
- Mollie Payments API en webhooks.
- SendGrid API voor e-mail.
- Zod voor validatie aan servergrenzen.
- `pnpm` als package manager.
- Vitest voor unit/integratietests en Playwright voor kritieke end-to-endflows.

Gebruik stabiele actuele versies die onderling compatibel zijn. Pin belangrijke versies en documenteer afwijkingen.

## 4. Designcanon

De referentie `docs/design/APPROVED_MASTER_SHOWCASE.png` is bindend voor de visuele richting.

Alle drie oppervlakken vormen één enterprisewaardig designsysteem:

- Duindorp SV royal blue, wit en beheerste grijstinten.
- Exact dezelfde typografie, spacing, radius, borders, schaduwen, iconstijl, badges, inputs en knoppen.
- Backoffice: informatierijk maar rustig en zeer scanbaar.
- Ledenportaal: toegankelijk, mobiel uitstekend, één duidelijke container per lid.
- Uitgifte: grote tapdoelen, minimale afleiding, operationeel snel.
- Geen gradients, glassmorphism, speelse consumer-appstijl of afwijkende subsystemen tenzij letterlijk in de canon vastgelegd.
- Gebruik het originele logo uit `docs/design/DUINDORP_SV_LOGO.png`; vervorm, herteken of herinterpreteer het niet.
- Nederlandse interfacecopy, correct gespeld en consistent.
- WCAG-principes, toetsenbordbediening, zichtbare focus en voldoende contrast zijn verplicht.

## 5. Architectuurregels

- Houd het een modulaire monoliet; geen microservices.
- Scheid UI, applicatielogica, domeinregels, data-access en externe integraties duidelijk.
- Vertrouw nooit bedragen, rollen, QR-status of betaalstatus uit de browser.
- Gebruik integer eurocenten; geen floating-point geldberekeningen.
- Alle mutaties lopen via gecontroleerde server-actions/route handlers/servicefuncties.
- Gebruik transacties voor samengestelde kritieke mutaties.
- QR- en OTP-geheimen worden alleen gehasht opgeslagen; plaintext tokens alleen eenmalig genereren/versturen.
- Sla e-mailadressen genormaliseerd op en behandel koppeling van ouder naar lid expliciet.
- Maak databaseconstraints voor invarianten; vertrouw niet alleen applicatievalidatie.
- Maak migrations vooruitrolbaar en veilig. Wijzig reeds toegepaste migrations niet.
- Houd generated types synchroon met de database.
- Geen persoonsgegevens in logs, QR-payloads, URL-querystrings of client analytics.

## 6. Veiligheid en privacy

- Least privilege voor iedere rol en iedere tabel.
- RLS standaard gesloten; policies expliciet en getest.
- `uitgifte` ziet uitsluitend gegevens die voor uitgifte nodig zijn.
- OTP: cryptografisch veilig, gehasht, korte levensduur, maximum pogingen, single-use en rate-limited.
- Ouder-sessies: opaque, herroepbaar, gehasht server-side en via Secure/HttpOnly/SameSite-cookie.
- Mollie-webhooks: status opnieuw bij Mollie ophalen, bedrag/valuta/order controleren, replay veilig verwerken.
- SendGrid-webhooks en callbacks valideren wanneer gebruikt.
- Secrets uitsluitend via environment variables; nooit committen.
- Auditlog is append-only vanuit normale applicatierollen.
- Voeg geen productiecredentials toe en voer geen productieacties uit zonder expliciete toestemming.

## 7. Autonoom werken

Werk zo autonoom mogelijk door tot een fase aantoonbaar klaar is.

Vraag niet om toestemming voor:

- normale reversibele implementatiekeuzes binnen canon en stack;
- het installeren van gangbare noodzakelijke dependencies;
- het aanmaken of wijzigen van bestanden binnen deze projectmap;
- lokaal linten, testen, bouwen, migreren en seeden;
- het oplossen van gevonden fouten binnen de huidige scope.

Vraag alleen bij een echte blocker, zoals:

- ontbrekende externe credentials die voor de volgende stap werkelijk noodzakelijk zijn;
- een onomkeerbare of productiegerichte externe actie;
- een directe canon-tegenstrijdigheid met materieel verschillende bedrijfsuitkomsten;
- risico op verlies van gegevens buiten deze projectmap.

Wanneer credentials ontbreken: implementeer de adapter, mocks/sandboxpad, env-validatie en tests volledig; markeer alleen de live verificatie als geblokkeerd.

## 8. Subagents en parallel werk

Gebruik subagents actief voor onafhankelijke, begrensde taken. De hoofdagent blijft eigenaar van architectuur, integratie en eindvalidatie.

Geschikte parallelle delegaties:

- canon- en scopecontrole;
- databaseschema, RLS en security review;
- design-systemanalyse en UI review;
- teststrategie en testgaten;
- Mollie/SendGrid-integratiereview;
- codebaseverkenning, lint/testtriage en documentatiecontrole.

Regels:

- Geef iedere subagent een exact afgebakend resultaat en relevante bestanden.
- Laat subagents bij voorkeur eerst lezen/reviewen; beperk parallelle schrijfopdrachten die dezelfde bestanden raken.
- Gebruik geïsoleerde Codex-worktrees/threads wanneer meerdere agents code wijzigen.
- Laat de hoofdagent alle resultaten verzamelen, conflicten oplossen, integreren en opnieuw volledig testen.
- Een subagent mag de canon, scope of architectuur niet zelfstandig wijzigen.

## 9. Samenloop met andere lokale projecten

Deze computer bouwt meerdere projecten tegelijk. Wees een goede buur.

- De beoogde repositorylocatie is `D:\\Codex\\repos\\duindorp-sv-tenueportaal`.
- Behandel `D:\\Codex\\repos` uitsluitend als bovenliggende verzamelmap; doorzoek, wijzig of initialiseiseer geen sibling-repositories.
- Werk uitsluitend binnen deze projectmap, behalve na expliciete toestemming.
- Stop, verwijder of herconfigureer nooit processen, containers, volumes, databases of repositories van andere projecten.
- Gebruik geen destructieve globale commands en geen globale package-installaties.
- Controleer bezette poorten voordat lokale services starten.
- Kies vrije, project-specifieke poorten en leg ze vast in `.env.local.example` en documentatie.
- Gebruik een unieke Supabase project-id, containernamen en lokale poortset.
- Als een poort bezet is: kies een andere; kill het bestaande proces niet.
- Beperk resources redelijk en sluit alleen processen die door deze repository zijn gestart.
- Gebruik projectlokale caches, tempbestanden en scripts.
- Maak geen wijzigingen in git global config, Docker Desktop global settings of systeeminstellingen.

## 10. Git en wijzigingen

- Initialiseer git in deze map als dat nog niet bestaat.
- Werk in kleine, coherente commits met duidelijke conventionele berichten.
- Commit nooit secrets, `.env.local`, dumps met persoonsgegevens of gegenereerde build-output.
- Verwijder of herschrijf geen bestaand werk zonder eerst de diff en het doel te begrijpen.
- Houd `docs/project/PROGRESS.md`, `DECISIONS.md`, `RISKS.md` en `TEST_EVIDENCE.md` actueel.

## 11. Kwaliteitspoorten

Een fase is pas klaar wanneer toepasselijk:

- requirements en canon zijn afgevinkt;
- formatter, lint en TypeScript slagen;
- unit- en integratietests slagen;
- kritieke Playwrightflows slagen;
- productiebuild slaagt;
- migrations en seed op een schone lokale database slagen;
- RLS-negatieve tests ongeautoriseerde toegang aantoonbaar blokkeren;
- UI handmatig op desktop en mobiel is gecontroleerd;
- loading, empty, error en success states bestaan;
- documentatie en env-example zijn bijgewerkt;
- security- en canonreview geen open blocker bevat.

Los fouten op; rapporteer geen fase als klaar met bekende rode gates.

## 12. Eerste bouwvolgorde

1. Preflight: canon samenvatten, risico's, plan, poorten en lokale prerequisites.
2. Repository en Next.js-fundering in de huidige map.
3. Design tokens, shells en gedeelde componenten voor de drie oppervlakken.
4. Supabase schema, migrations, RLS, seed en medewerkerrollen.
5. Sportlink CSV-import en ledenbeheer.
6. Artikelen, varianten, maten, bestellingen en exacte handmatige betalingen.
7. Ouder-OTP, sessies, optionele ledenkoppeling en dashboard per lid.
8. Leveringen, artikelstatussen, QR en uitgifte.
9. SendGrid-templates/bulkmail en Mollie sandbox/webhooks.
10. Exports, audit, hardening, E2E en release-evidence.

Behoud deze volgorde tenzij een gedocumenteerde technische afhankelijkheid een kleine wijziging vereist. Bouw geen toekomstige ideeën uit de canon.
