# Duindorp SV Tenueportaal — bindend MVP-addendum v1.1

Status: goedgekeurd door de product owner op 2 augustus 2026.

Dit addendum vervangt canon v1.0 uitsluitend waar onderstaande bepalingen daarvan
afwijken. Voor alle niet-genoemde onderwerpen blijven de PDF-canon, de canonieke
tekst en het goedgekeurde ontwerp ongewijzigd bindend. De applicatie blijft één
single-tenant Duindorp SV-product en een modulaire monoliet.

## 1. Domeinkern en seizoenen

- Het kledingpakket is het commerciële totaalproduct. Pakketcomponenten zijn de
  afzonderlijke logistieke subproducten.
- Een lid heeft een duurzame clubidentiteit en per seizoen een expliciete
  lid-seizoenrelatie met team, toegang, pakketorder, maten en processtatussen.
- Per lid-seizoen bestaat maximaal één actieve primaire pakketorder.
- Een pakketorder heeft één immutable naam-, prijs-, valuta-, revisie- en
  inhoudsnapshot. Iedere pakketregel heeft daarnaast een immutable productnaam-,
  variant-/maat- en uitgegeven-maatsnapshot zodra die feiten ontstaan.
- Maatbevestiging, betaling, fysieke voorraad, allocatie, QR-beschikbaarheid en
  uitgifte zijn afzonderlijke statusassen. Er komt geen samengestelde mega-status.
- Een pakket mag in delen worden gereserveerd, klaargezet en uitgegeven; dezelfde
  orderidentiteit blijft voor naleveringen gelden.

## 2. Ledenidentiteit, geboortedatum en geslacht

- Herimport matcht primair op het Sportlink-relatienummer of een andere expliciete
  externe lid-ID. Naam en gedeeld ouder-e-mailadres zijn nooit zelfstandig uniek.
- Geboortedatum (`date_of_birth`) wordt, indien aangeleverd, duurzaam als
  identiteitshulp opgeslagen. Zij mag geen stilzwijgende match forceren.
- Geboortedatum is uitsluitend zichtbaar voor:
  - een beheerder met een actuele AAL2-sessie;
  - een ouder met een actuele, door beheer verleende grant voor dat eigen lid.
- Kledingcommissie, uitgifte en leverancier ontvangen geen geboortedatum.
- Geslacht wordt als expliciet, normaliseerbaar lidattribuut ondersteund. Onbekend of
  niet opgegeven blijft een geldige, zichtbare toestand en wordt nooit gegokt.
- Een geldige uitgiftescan toont van de identiteit alleen de voornaam en het
  geregistreerde geslacht. Free-Kick krijgt voor planning uitsluitend aggregaten.
  Een Free-Kick-medewerker die fysiek uitgeeft, heeft daarnaast de afzonderlijke rol
  `uitgifte` en ziet binnen die scan eveneens alleen voornaam en geslacht.

## 3. Dynamische Sportlink-import

- Een upload wordt eerst byte-, tijd-, rij-, kolom-, encoding-, delimiter- en
  headerbegrensd gelezen. Een beheerder kiest daarna per bronkolom: negeren,
  standaardveld of maat van één concreet actief product.
- Standaardvelden zijn naamdelen, e-mail, team, relatienummer, geboortedatum en
  geslacht. Alleen geselecteerde kolommen worden naar het duurzame domein verwerkt.
- Een mappingpreset is gemak, geen bewijs: ieder doel, product en iedere maattabel
  wordt per upload opnieuw gevalideerd.
- Preview en dry-run tonen minimaal create, update, skip, protected, conflict en
  error, inclusief unieke bronmaatwaarden en herkenningsaantallen.
- Geldige geïmporteerde maten zijn voorgeselecteerd maar onbevestigd. Een bevestigde
  maat wordt nooit stil door herimport overschreven.
- Maatnormalisatie beperkt zich tot veilige Unicode-/whitespace-/case-normalisatie
  en daarna exacte code-, label- of aliasmatch. Er is geen fuzzy matching.
- `Anders…` is geen variant of SKU. De ruwe waarde en verplichte toelichting vormen
  een conflict totdat beheer een echte variant koppelt of het assortiment bewust
  uitbreidt.
- Commit is idempotent, transactioneel per begrensde batch en bewaart een resultaat
  per rij. Niet-geselecteerde kolommen worden niet duurzaam opgeslagen; versleutelde
  ruwe stagingdata heeft een korte configureerbare retentie.
- Import verleent nooit portaaltoegang en verstuurt nooit automatisch e-mail.

## 4. Portaaltoegang en gezin

- Alleen een beheerder kan portaaltoegang activeren of intrekken.
- Activatie heeft een preflight per genormaliseerd ouder-e-mailadres en maakt
  expliciete grants voor alleen de geselecteerde lid-seizoenen. Ontbrekende,
  ongeldige of verdachte gezinskoppelingen blokkeren de betreffende selectie.
- Eén gedeeld ouderadres gebruikt één ouderaccount en één uitnodiging per run.
  Een bestaand ouderaccount krijgt geen dubbele identiteit.
- De uitnodiging bevat uitleg en de portaalroute, geen login- of magic-linktoken.
  Een zescijferige OTP ontstaat pas na een eigen loginverzoek en behoudt het huidige
  expiry-, rate-limit-, single-use-, anti-enumeratie- en sessiebeleid.
- Ouders kunnen niet zelfstandig andere kinderen koppelen of grants verruimen.

## 5. Pakketten, producten en maten

- Beheer maakt zelf producten, maattabellen, varianten en pakkettemplates aan.
  Er worden geen Speler-, Keeper-, product- of maatfixtures als bedrijfsdata geseed.
- Een pakkettemplate hoort bij één seizoen en bevat naam, omschrijving, prijs in
  eurocenten, valuta, revisie, actief/default en productregels met aantallen, zonder
  gekozen maten.
- Per seizoen bestaat maximaal één actieve standaardtemplate. De beheerder kiest die
  expliciet; de applicatie gokt geen Speler- of Keeperpakket.
- Ouders bevestigen alle verplichte pakketmaten pakketbreed. Een geldige importmaat
  staat op `Nog controleren`; ontbrekend en `Anders…` blijven zichtbaar.
- Vóór reservering is wijzigen en opnieuw bevestigen toegestaan. Na reservering
  wordt een wijziging een beheeractie; na uitgifte blijft de regel vergrendeld.
- Pakketwissel vóór betaling en reservering is toegestaan. Daarna is uitsluitend
  een geaudite beheerworkflow toegestaan. Prijsverschil, bijbetaling of refund wordt
  nooit automatisch uitgevoerd.

## 6. Betaling, voorraad en allocatie

- Mollie is de openbare pakketbetaling. Webhook en redirect zijn idempotent en de
  server verifieert payment, bedrag, EUR-valuta, pakketorder en omgeving opnieuw bij
  Mollie.
- Alleen een beheerder mag `kas betaald` registreren, altijd onder AAL2 en voor het
  exacte openstaande bedrag met reden, actor, tijd, idempotentie en audit.
- Bestaande pinfunctionaliteit blijft aanvankelijk achter een standaard uitgeschakelde
  feature flag en wordt niet stil verwijderd.
- Onbetaalde pakketten tellen mee in de totale vraag maar krijgen geen harde
  reservering. Er is geen tijdelijke onbetaalde hold; eventuele
  beschikbaarheidsmail is expliciet niet-gegarandeerd.
- Voorraad wordt afgeleid uit een append-only mutatiejournaal per productvariant.
  Een leveringconcept muteert niets. De totale levering wordt pas atomair geboekt
  nadat iedere actieve maatregel een aantal of expliciet nul en een bevestiging heeft.
- Betaalde, maatgeldige open regels worden gealloceerd volgens FIFO vanaf het latere
  tijdstip van geldige maat en betaling. Een override vereist beheerbevoegdheid,
  reden en audit.
- De lagevoorraaddrempel is standaard 10 en configureerbaar. Actiepunten dedupliceren
  per variant en tekortepisode.

## 7. QR, scanner-PWA en uitgifte

- De herbruikbare QR bevat geen PII en geen bearer in een queryparameter. Een random,
  gehasht en environment-peppered locator wordt via een URL-fragment of rechtstreeks
  door de scanner gelezen en via een geauthenticeerde POST ingewisseld voor een
  kortlevende, eenmalige scanbevoegdheid.
- De QR wordt alleen bruikbaar bij een volledig betaald pakket én minimaal één harde
  afhaalklare allocatie. Rotatie trekt de oude identiteit gecontroleerd in.
- Uitgifte vereist op transactiemoment: een geldige scanbevoegdheid, een actuele
  bevoegde medewerkerssessie, betaling en concrete reserveringen.
- Een ongeldige of onbevoegde scan toont geen persoonsgegevens. Een geldige scan toont
  uitsluitend voornaam, geslacht, afhaalklare regels/maten, reeds afgehaald en nog
  wachtend.
- Uitgifte schrijft één immutable event met geselecteerde concrete regels. De laatste
  deeluitgifte veroorzaakt alleen `PACKAGE_COMPLETE`; eerdere uitgiftes veroorzaken
  precies één `PARTIAL_PICKUP`.
- Alleen de scannerroute is een installeerbare PWA. Zij bewaart uitsluitend de
  beveiligde medewerkerssessie volgens het sessiebeleid, werkt netwerkafhankelijk en
  ondersteunt geen offline betaling, voorraadmutatie of uitgifte. Backoffice en
  ledenportaal blijven gewone browserapplicaties.

## 8. Rollen en privacy

- De drie personeelsrollen blijven `beheerder`, `kledingcommissie` en `uitgifte`.
- Leverancierstoegang is een afzonderlijke, beperkte principal en wordt niet als
  vierde personeelsrol toegevoegd.
- Beheerder beheert toegang, kas, pakketten/default/prijs, templates, branding,
  campagnes, medewerkers en correcties.
- Kledingcommissie beheert operationeel producten, maten, conflicten, voorraad,
  leveringconcepten en gepubliceerde campagnes, maar geen DOB, kas of
  portaaltoegang. Een totale levering mag alleen door beheerder of kledingcommissie
  definitief worden geboekt.
- Leverancier ziet planning uitsluitend als aantallen per product, maat en geslacht,
  inclusief onbetaalde open vraag, zonder naam, e-mail, geboortedatum, team,
  pakketorder of individuele betaalstatus.
- Ouder ziet alleen lid-seizoenen waarvoor beheer een actuele grant heeft.
- Alle rechten gelden server-side én in RLS/RPC's; UI-verbergen is nooit autorisatie.

## 9. E-mail, templates, acties en branding

- Externe e-mail gebruikt versieerbare draft/published/archive-templates met
  onderwerp, preheader, gesanitiseerde TipTap-body, tekstfallback, getypeerde
  shortcodes, beschermde blokken en immutable rendersnapshot.
- De catalogus en segmentatieregels uit de goedgekeurde Fase B-opdracht zijn bindend.
  Doelgroep en stopvoorwaarden worden onmiddellijk vóór enqueue opnieuw gevalideerd;
  retries, scheduler en handmatig gebruik dezelfde idempotentie en suppressie.
- Nieuwe reminderregels zijn na release standaard inactief. Tijdzone is
  `Europe/Amsterdam`; standaard quiet hours zijn 20:00–08:00 lokale tijd.
- Actiepunten gebruiken één niet-destructief, deduplicerend model met tenant
  (impliciet Duindorp SV), seizoen, object, episode, SLA, veilige context en
  geaudite oplossing.
- Open- en kliktracking staan standaard uit.
- De oorspronkelijke Duindorp SV-identiteit en het logo blijven vast. De beheerbare
  operationele merk- en contactinstellingen worden aanvankelijk gevuld met:
  - afzendernaam/contact: `Kledingcommissie Duindorp SV`;
  - verenigingsadres: `Houtrustlaan 1`, `2566 ZW Den Haag`;
  - from en reply-to: `kleding@duindorpsv.nl`;
  - afhaalnaam: `Free-Kick Sport`;
  - afhaaladres: `De Savornin Lohmanplein 45`, `2566 AE Den Haag`;
  - privacyroute: `https://duindorpsv.nl/privacy`.

## 10. Migratie, staging en release

- Uitsluitend nieuwe forward-only migraties: expand, gecontroleerde backfill en
  reconciliatie, dual compatibility achter standaard uitgeschakelde feature flags,
  en pas later contract.
- Legacy bestellingen krijgen een generieke `Legacy tenue`-pakketsnapshot; er wordt
  nooit Speler of Keeper gegokt. Bestaande voorraad wordt als gecontroleerde opening
  balance in het journaal vastgelegd.
- Ieder verschil in geld, voorraad, reservering of uitgifte blokkeert productie.
- Staging wordt, na een environment-identiteitscheck, tellingendry-run en back-up,
  opgeschoond via een expliciete tabelallowlist. Medewerkerprofielen en bijbehorende
  Auth-accounts vallen nooit in die allowlist. Dezelfde wisactie kan niet tegen
  productie draaien.
- De aangeleverde Sportlink-CSV wordt niet als persistent fixturebestand gecommit.
- Staging-acceptatiehelpers en testfixtures leven buiten productiemigraties en zijn
  alleen via een expliciete staging-gate uitvoerbaar.
- Staging en productie promoveren exact hetzelfde immutable artifact met commit,
  digest, SBOM en checksums. Production wordt nooit automatisch gedeployed.
