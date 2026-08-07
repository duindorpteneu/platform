# Stagingverificatie

Status: nog uit te voeren op een externe stagingomgeving
Canon: MVP v1.0, sectie 19 en 20.1, plus goedgekeurd addendum v1.1
Artefact/commit-SHA: `________________`
Staging-URL: `________________`
Testrun (UTC): `________________`
Uitvoerder(s): `________________`

Deze verificatie gebruikt alleen fictieve gegevens en provider-testmodi. Elk scenario krijgt een bewijslink naar geautomatiseerde output, screenshot of geredigeerd operationeel record. Bewijs bevat geen e-mailadres, OTP, QR-token, cookie, key of volledige webhookbody.

## 1. Toelatingsvoorwaarden

- [ ] CI, lokale releasegate en [SECURITY_ACCEPTANCE.md](SECURITY_ACCEPTANCE.md) zijn groen op dezelfde commit-SHA.
- [ ] Staging en production zijn aantoonbaar gescheiden volgens [ENVIRONMENT_MATRIX.md](ENVIRONMENT_MATRIX.md).
- [ ] Alle migraties zijn schoon gereplayed en de productieachtige Phase-B-upgrade/reconciliatie is groen. Er is geen businessseed voor leden, producten, maten of pakketten.
- [ ] HTTPS, HSTS, CSP, secure cookies en no-store voor gevoelige responses zijn actief.
- [ ] De actieve Caddy 2.10+-configuratie bevat de route-specifieke request-bodycaps; de deploy-eindprobe heeft alle vier chunked routegroepen met proxy-`413` bewezen.
- [ ] Eén fictief account per staffrol heeft TOTP/AAL2; er is ook een geblokkeerd account.
- [ ] Zelfopruimende `example.invalid`-acceptatiedata kan run-uniek worden gemaakt voor gedeeld account, betaald/onbetaald, nalevering en dubbele uitgifte. De gebruiker beheert de echte stagingproducten, maten en pakketten zelf.
- [ ] Mollie staat in testmode en webhook gebruikt publiek HTTPS.
- [ ] De Mollie-acceptatie vindt een bestaand actief open stagingseizoen en `mollie_enabled=true`; het productschema retourneert voor alle vier verwijderde fixture-RPC's `404/PGRST202`.
- [ ] SendGrid-afzender/template en signed event webhook zijn staging-specifiek.
- [ ] Publieke en interne health, queue, webhook- en reconciliatiemonitoring zijn zichtbaar.
- [ ] Providerflags starten uit en worden alleen binnen de expliciete providerscenario’s aangezet.

## 2. Verplichte end-to-endscenario’s

### E2E-01 — Sportlinkimport

- [ ] Upload de eerder gedeelde Sportlinkvorm en aanvullende fictieve CSV's voor UTF-8/BOM, komma/puntkomma, quoted newline, duplicate headers, limieten en schadelijke/formulewaarden.
- [ ] Kies per bronkolom expliciet negeren, standaardveld (naam, e-mail, team, relatienummer, DOB, geslacht) of productmaat; toon per product de actieve maattabel en aantallen herkend/leeg/onbekend/onveilig.
- [ ] Hergebruik een mappingpreset en bewijs dat headers, catalogushash, seizoen en unieke waarden opnieuw worden gevalideerd.
- [ ] Dry-run onderscheidt create/update/skip/protected/conflict/error. Ambigue naam/e-mail/DOB-match blokkeert; Sportlink-relatienummer heeft de voorkeur.
- [ ] Een geldige geïmporteerde maat is voorgeselecteerd maar onbevestigd; bevestigde maten worden niet overschreven. `XXXL` tegen maximaal `XXL` wordt `Anders…`-conflict met ruwe waarde, nooit variant.
- [ ] Commit verwerkt transactionele idempotente batches, bewaart rijresultaten, verleent geen portaaltoegang en verstuurt geen mail. Herhaling maakt geen dubbel lid.

Verwacht canoniek resultaat: correcte preview; commit alleen geldige rijen; batch gelogd.
Bewijs: `________________`

### E2E-02 — Eén e-mail, één lid

- [ ] Activeer als AAL2-beheerder eerst expliciet portaaltoegang voor het geselecteerde lid-seizoen; controleer preflight en één tokenloze uitnodiging.
- [ ] Vraag met een bekend fictief e-mailadres een zescijferige code aan.
- [ ] Gebruik de code binnen tien minuten exact één keer.
- [ ] Alleen het vooraf gegrante lid-seizoen is zichtbaar; OTP of e-mailmatch maakt geen nieuwe koppeling.

Verwacht canoniek resultaat: code tien minuten geldig; uitsluitend vooraf verleende toegang; dashboard zichtbaar.
Bewijs: `________________`

### E2E-03 — Eén e-mail, drie leden

- [ ] Selecteer als AAL2-beheerder twee van drie fictieve kinderen met hetzelfde genormaliseerde ouderadres; preflight toont alle drie en blokkeert verdachte/ongeldige adressen.
- [ ] Activeer alleen de twee gekozen grants. Controleer één bestaand/nieuw ouderaccount en één geconsolideerde uitnodiging zonder login- of OTP-token.
- [ ] Vraag met het gedeelde fictieve e-mailadres een code aan.
- [ ] Dashboard toont precies de twee gegrante kinderen; het derde blijft via UI, directe API en RLS onzichtbaar.
- [ ] Activeer het derde later als beheerder en bewijs dat hetzelfde ouderaccount een nieuwe grant krijgt zonder dubbele identiteit of automatisch vierde kind.
- [ ] Elk lid-seizoen behoudt eigen pakket, bedrag, maat-, betaal-, QR- en uitgiftehistorie.

Verwacht canoniek resultaat: één gedeeld account, uitsluitend beheerdergrants, geen automatische gezinskoppeling.
Bewijs: `________________`

### E2E-04 — OTP-bruteforce en enumeratie

- [ ] Voer vijf foutieve codes voor dezelfde challenge in.
- [ ] De challenge wordt onbruikbaar; ook de correcte oude code faalt en een nieuwe code is vereist.
- [ ] Bekend en onbekend e-mailadres krijgen dezelfde neutrale HTTP-status, responsevorm en gebruikerscopy.
- [ ] Controleer 60-secondenresend, maximaal vijf aanvragen per uur per e-mail en IP-limiet; overschrijding is neutraal/rate-limited.

Verwacht canoniek resultaat: code ongeldig; nieuwe code vereist; geen accountinformatie gelekt.
Bewijs: `________________`

### E2E-05 — Mollie exact paid

- [ ] Start `.github/workflows/staging-mollie-acceptance.yml` met de exacte gedeployde SHA en bevestiging `STAGING-MOLLIE-TESTMODE`; de workflow weigert iedere andere host/ref, een `live_`-key en een onverwacht `MOLLIE_PROFILE_ID`.
- [ ] Zet `MOLLIE_ENABLED=true` in staging en start voor één lid een testmodebetaling voor exact het server-side orderbedrag in EUR.
- [ ] Rond hosted checkout af; de redirect alleen wijzigt paid niet.
- [ ] Laat de publiek bereikbare webhook de actuele betaling bij Mollie ophalen en verwerken.
- [ ] Controleer direct na de paid-webhook één immutable paid-record en één mailjob, maar exact nul harde allocaties, nul afhaalklare regels en nul actieve QR-identiteiten. Betaling alleen mag de QR nooit activeren.
- [ ] Laat het target-locked SQL-harnas daarna voor dezelfde betaalde order één run-uniek tijdelijk product, variant, bevestigde maat, orderregel en één stuk voorraad combineren tot exact één harde allocatie. Controleer binnen diezelfde transactie één afhaalklare regel, `qrBusinessEligible=true`, `qrUsable=true` en exact één actieve QR-locator.
- [ ] Rol de voorraad-, allocatie- en QR-readiness-transactie altijd terug. Controleer dat de externe SQL-runner geen globale instelling of duurzame fixturetabel maakt en dat de tijdelijke product-, variant- en orderregel plus alle run-unieke ouder-, lid-, order-, payment-, e-mail- en eventfixtures in `finally` zijn verwijderd; het testmode-providerrecord blijft zonder PII in het stagingprofiel staan.

Verwacht canoniek resultaat: payment paid zonder allocatie/QR; na één tijdelijke harde allocatie is QR-readiness bewezen; de rollback en finale cleanup laten geen productfixture achter.
Bewijs: `________________`

### E2E-06 — Mollie bedrag-/metadata-afwijking

- [ ] Richt via een afgeschermde stagingfixture een Mollie-testbetaling in waarvan bedrag of metadata niet overeenkomt met de lokale order.
- [ ] Maak de lokale attempt via de echte payment-create-route en wijzig uitsluitend in Mollie-testmode het `payment_id` in de providermetadata naar een andere run-unieke fixture-UUID.
- [ ] Verwerk de webhook via dezelfde publieke productiecode en server-side providerlookup.
- [ ] Controleer dat order/payment niet paid worden, geen QR/mail ontstaat, uitgifte geblokkeerd blijft en `reconciliation_issue` plus manual-reviewaudit zichtbaar zijn.
- [ ] Voer handmatige review uit zonder historie te overschrijven.

Verwacht canoniek resultaat: order niet paid; security/error-event; handmatige review.
Bewijs: `________________`

### E2E-07 — Webhookreplay

- [ ] Lever na de eerste paid-verwerking exact dezelfde klassieke form-webhook driemaal gelijktijdig af via de publieke staging-URL.
- [ ] Controleer één lokale statuswijziging, één auditketen en geen dubbele e-mail- of QR-actie. Na rollback van de tijdelijke readiness-transactie blijft de duurzame paid-snapshot nog steeds zonder harde allocatie en zonder QR.

Verwacht canoniek resultaat: één statuswijziging; geen dubbele mail/QR.
Bewijs: `________________`

### Mollie-refundacceptatie

- [ ] Start via de Mollie test-API een volledige refund van de door E2E-05 betaalde testbetaling; het portaal biedt bewust geen refundknop.
- [ ] Wacht tot Mollie `amountRefunded` voor het volledige EUR-bedrag retourneert en lever het provider-ID via de publieke stagingwebhook af.
- [ ] Controleer paymentstatus `refunded`, één refundevent/audit, nul actieve QR-codes, geen uitgifterecht en geen tweede betalingsmail. Deze providerflow houdt na de teruggedraaide readiness-proef aantoonbaar geen QR over; QR-intrekking van een duurzaam gealloceerde order blijft aanvullend onderdeel van de database- en scanneracceptatie.
- [ ] Bewijs dat de workflow uitsluitend de `test_`-key en het verwachte stagingprofiel gebruikte en geen checkout-URL, cookie, key, e-mailadres of webhookbody logde of als artefact opsloeg.

Verwacht canoniek resultaat: refund zichtbaar; actieve QR ingetrokken; geen nieuw uitgifterecht.
Bewijs: `________________`

### E2E-08 — Exacte kasbetaling

- [ ] Registreer uitsluitend als AAL2-beheerder kas voor een open pakketorder; kledingcommissie en AAL1 krijgen 403.
- [ ] Reden en exact server-side pakketbedrag zijn verplicht.
- [ ] UI accepteert geen vrij bedrag; server herleest exact verschuldigd bedrag.
- [ ] Controleer paid, immutable paymentrecord, methode, timestamp en actor in audit.
- [ ] Herhaling maakt geen tweede succesvolle betaling.

Verwacht canoniek resultaat: paid; immutable paymentrecord; actor gelogd.
Bewijs: `________________`

### E2E-09 — Deellevering

- [ ] Ontvang en reserveer broek en sokken; ontvang het shirt niet.
- [ ] Controleer per artikelregel twee keer “Af te halen” en shirt “Nalevering”.
- [ ] Queue/verstuur maximaal één gereedmelding per lid.

Verwacht canoniek resultaat: broek/sokken gereed, shirt nalevering, bulkmail per lid.
Bewijs: `________________`

### E2E-10 — Onbetaalde QR-scan

- [ ] Bewijs dat een onbetaalde order geen actieve QR-locator heeft, ook als fysieke voorraad beschikbaar is.
- [ ] Scan een willekeurige, verlopen of ingetrokken locator.
- [ ] Uitgifterol ziet geen PII en kan geen regel voltooien.
- [ ] API-commit is eveneens geweigerd en maakt geen fulfilmentrecord.

Verwacht canoniek resultaat: geen uitgifte mogelijk.
Bewijs: `________________`

### E2E-11 — Betaalde QR met twee gereedstaande regels

- [ ] Scan een actieve QR van een betaalde order met twee gereedstaande regels.
- [ ] Selecteer beide en bevestig eenmaal.
- [ ] Controleer één atomaire commit, twee fulfilmentrecords, status “Afgehaald” en juiste actor.

Verwacht canoniek resultaat: selectie en atomaire uitgifte; regels afgehaald.
Bewijs: `________________`

### E2E-12 — Gelijktijdige uitgifte

- [ ] Open dezelfde gereedstaande regel op twee apparaten/sessies.
- [ ] Bevestig zo gelijktijdig mogelijk.
- [ ] Controleer exact één commit; de tweede krijgt een actuele conflictmelding en geen extra fulfilment.

Verwacht canoniek resultaat: één commit; tweede actuele conflictmelding.
Bewijs: `________________`

### E2E-13 — Latere nalevering met dezelfde QR

- [ ] Ontvang en reserveer later uitsluitend het shirt van E2E-09.
- [ ] Scan exact dezelfde nog actieve QR.
- [ ] Alleen het shirt is selecteerbaar; eerder afgehaalde regels blijven immutable.

Verwacht canoniek resultaat: dezelfde QR; alleen shirt uitgegeven.
Bewijs: `________________`

### E2E-14 — QR-rotatie

- [ ] Roteer een actieve QR als beheerder/kledingcommissie met verplichte reden.
- [ ] Bewijs dat de oude QR faalt en de nieuwe actief is zonder nieuw order.
- [ ] Verstuur de nieuwe QR gecontroleerd opnieuw en controleer audit.

Verwacht canoniek resultaat: oude code ongeldig; nieuwe actief; mail opnieuw mogelijk.
Bewijs: `________________`

### E2E-15 — Formuleveilige export

- [ ] Maak een fictief lid met een naam die met `=` begint.
- [ ] Exporteer als beheerder/kledingcommissie CSV en XLSX met een verplicht expliciet seizoen en server-side filters.
- [ ] Open beide bestanden in spreadsheetsoftware en controleer dat geen formule wordt uitgevoerd.
- [ ] Herhaal minimaal voor tekst die begint met `+`, `-`, `@`, tab en carriage return.
- [ ] Controleer UTF-8 BOM voor CSV, neutrale bestandsnaam en exportaudit; uitgifterol krijgt geen export.

Verwacht canoniek resultaat: bestand opent zonder formule-uitvoering.
Bewijs: `________________`

### E2E-16 — Uitgifterol buiten scope

- [ ] Probeer als `uitgifte` iedere backofficepagina en relevante backoffice-/export-/beheer-API.
- [ ] Controleer 403 of veilige redirect zonder dataresponse, zowel via UI als directe request.
- [ ] Uitgiftescan/search toont uitsluitend de minimale operationele gegevens.

Verwacht canoniek resultaat: 403/redirect; geen dataresponse.
Bewijs: `________________`

### E2E-17 — Ouder naar niet-gekoppeld lid

- [ ] Gebruik een geldige oudersessie en vraag een bekend maar niet-gekoppeld `member_id` op via alle ouderroutes.
- [ ] Controleer 403/404 zonder naam, e-mail, team, bedrag, order- of QR-data.
- [ ] RLS-negatieve test bevestigt dezelfde grens direct op database/API.

Verwacht canoniek resultaat: 404/403; geen liddata.
Bewijs: `________________`

### E2E-18 — Tijdelijke SendGridstoring

- [ ] Laat de stagingtestharness een tijdelijke netwerk-/providerfout teruggeven zonder productiecodepad te omzeilen.
- [ ] Voer worker uit en controleer retry met oplopende attempt count/backoff en zichtbare UI-status.
- [ ] Herstel provider, voer volgende worker-run uit en controleer één verzending/provider-message-ID.
- [ ] Replay/dubbelklik veroorzaakt geen tweede verzending.

Verwacht canoniek resultaat: retry; UI toont status; geen dubbele verzending.
Bewijs: `________________`

### E2E-19 — Pakket, revisie en immutable snapshot

- [ ] Maak als beheerder zelf twee pakketten met eigen prijs, producten en aantallen; publiceer revisies en wijs exact één seizoensdefault aan.
- [ ] Kies een pakket voor een lid-seizoen en wijzig daarna templateprijs/inhoud.
- [ ] Controleer dat ordernaam, prijs, valuta, revisie en productinhoud snapshots blijven.
- [ ] Wissel vóór betaling/reservering en voer na betaling/reservering uitsluitend de geaudite beheerworkflow met reden, preflight en expliciete prijsverschilactie uit; er vindt geen automatische refund plaats.

### E2E-20 — Pakketbrede maatbevestiging en conflict

- [ ] Toon ieder maatproduct mobiel met naam/afbeelding, maat, herkomst en status.
- [ ] Bevestiging blokkeert zolang een verplicht product leeg is; geïmporteerde maat toont `Nog controleren`.
- [ ] Zelf gekozen `Anders…` vereist toelichting, stopt ledenherinnering en houdt één beheeractie open.
- [ ] Wijzig vóór reservering direct; na reservering ontstaat één verzoek en geaudite vrijgave; na uitgifte blijft de regel vergrendeld.

### E2E-21 — Levering, FIFO en notificatievoorstel

- [ ] Maak een leveringconcept met voor iedere actieve productmaat een aantal of expliciet `0 – niet geleverd` en afzonderlijke bevestiging.
- [ ] Bewijs dat concept geen voorraad/QR/mail wijzigt en onvolledig posten blokkeert.
- [ ] Post totaal atomair; controleer fysiek, gereserveerd, vrij, totale vraag, betaald/onbetaald, afgehaald en tekort.
- [ ] Alleen betaalde maatgeldige regels reserveren FIFO; override vereist reden/audit.
- [ ] Bevestig een notificatievoorstel met geschikt/overgeslagen/geblokkeerd, inclusief meer dan 500 geschikte regels via impliciete all-minus-exclusionsselectie.

### E2E-22 — Action items, bulkpreflight en saved views

- [ ] Open één gededupliceerde episode voor maatconflict, lage/nulvoorraad, betaald-zonder-voorraad, queuefout en afhaalachterstand.
- [ ] Wijs toe/start/los op; afwijzen vereist reden en herstelde toestand auto-resolvet waar gedefinieerd.
- [ ] Sla een ledenfilter op en voer bulkactie alleen na doelgroep-preflight, mailpreview en aantallen geschikt/overgeslagen/geblokkeerd uit.

### E2E-23 — DOB en multi-seizoen privacy

- [ ] Eén lid heeft twee seizoenen met verschillende teams, pakketten, maten, betalingen, QR en fulfilment; geen scherm/RPC/export/mail vermengt die.
- [ ] Beheerder en expliciet gegrante ouder zien DOB van het bedoelde lid; kledingcommissie, uitgifte en leverancier krijgen geen DOB.
- [ ] Oudersessie voor seizoen A kan seizoen B zonder actieve grant niet benaderen.

### E2E-24 — Free-Kick leverancierprivacy

- [ ] Leverancierprincipal met expliciete seizoensgrant ziet alleen aggregaten per product/maat en vraag per geslacht, inclusief onbetaalde open vraag.
- [ ] Directe requests naar lid, naam, e-mail, DOB, team, order, betaling en uitgifte worden geweigerd.
- [ ] Grantwijziging/rotatie trekt sessies in; leveringinvoer kan hoogstens concept zijn.

### E2E-25 — Scanner-PWA op echte apparaten

- [ ] Installeer uitsluitend `/uitgifte` als PWA op de afgesproken echte iOS-/Androidapparaten; beheer/portaal blijven browser.
- [ ] Bewijs camera-permission toegestaan/geweigerd/hersteld, sessiebehoud na appsluiting en verplichte online status.
- [ ] Netwerkverlies blokkeert scan/uitgifte veilig; er is geen offline betaling of fulfilment.
- [ ] Geldige scan toont alleen voornaam, geslacht, gereedstaande maten, reeds afgehaald en nog wachtend; geen DOB/achternaam/e-mail/team/relatienummer.

### E2E-26 — Mail-v2, TipTap, segmentatie en reminders

- [ ] Publiceer/test alle 19 catalogustemplates met verplichte beschermde nodes, typed shortcodes, sanitizer, tekstfallback en desktop/mobile/dark preview.
- [ ] Scripts, iframes, formulieren, events, willekeurige CSS en onveilige URL's blokkeren; LOGIN_OTP-node blijft beschermd en OTP wordt niet duurzaam opgeslagen.
- [ ] Segmentatie onderscheidt ontbrekend, onbevestigd, bevestigd en `Anders…`; doelgroep wordt vlak voor enqueue herbeoordeeld en gedeeld account krijgt één geconsolideerde mail per run.
- [ ] Reminderregel respecteert Europe/Amsterdam, quiet hours, cooldown, maximum/einddatum en stopvoorwaarden; nieuwe regel start inactief.

### E2E-27 — SendGrid inbox, events en definitieve fout

- [ ] Dedicated stagingaccountfingerprint klopt voor admin- en Mail Send-key.
- [ ] Testdelivery komt werkelijk in de TLS-IMAP-testinbox aan.
- [ ] Twee signed eventleveringen/replays projecteren exact één attempt; bounce/drop/failure maakt één intern actiepunt en monitoringalarm.

### E2E-28 — Scannerzoekherstel zonder bypass

- [ ] Zoek op voornaam/relatienummer uitsluitend als bevoegde medewerker en gebruik het resultaat alleen om dezelfde QR-orderidentiteit te herstellen.
- [ ] Zonder geldige QR-exchange, volledige betaling en harde reservering blijft commit geweigerd.
- [ ] Ongeldige/onbevoegde zoek- of scanrequest toont geen PII.

## 3. Security-, browser- en toegankelijkheidsgates

- [ ] Anoniem, ouder, beheerder, kledingcommissie en uitgifte zijn tegen alle gevoelige routes getest.
- [ ] State-changing cookieauthrequests zonder/onjuiste CSRF, Origin of Host worden vóór domeinactie geweigerd.
- [ ] OTP-request/verify, Mollie-create, QR-lookup, zoeken en export retourneren aantoonbaar een begrensde 429/neutrale response.
- [ ] Upload controleert requestgrootte, CSV-extensie, MIME, inhoud, rij/kolom/cellimieten en binaire/polyglotinput.
- [ ] CSP bevat minimaal `default-src`, `base-uri`, `object-src` en `frame-ancestors`; productie bevat geen `unsafe-eval`.
- [ ] HSTS, nosniff, referrer- en permissionspolicy gelden voor pagina, API, redirect en foutresponse.
- [ ] Logs en auditbewijs bevatten correlation-id maar geen secrets, tokens, e-mails, namen of webhookbody.
- [ ] Chrome, Edge en Safari huidig/vorig zijn gedekt; mobiele Safari/Chrome voor leden. Alleen de scanner gebruikt PWA-installatie en echte camera-apparaten.
- [ ] Viewports: leden vanaf 360 px, uitgifte vanaf 768 px, backoffice op 1280 px.
- [ ] Kernflows zijn volledig per toetsenbord uitvoerbaar; focus zichtbaar; labels/status/fouten screenreaderbruikbaar.
- [ ] Contrast voldoet WCAG 2.2 AA en status is niet alleen kleur.
- [ ] Reduced-motionvoorkeur schakelt niet-essentiële motion uit.

Bewijs: `________________`

## 4. Operations- en herstelgates

- [ ] E-mailworker iedere minuut en de onafhankelijke vijfminutenretentie zijn minimaal twee cycli gevolgd, inclusief één gecontroleerde e-mailfout waarbij cleanup wel doorgaat.
- [ ] Interne health toont queue, stale/failed jobs, webhookmismatches en betaalreconciliatie zonder PII.
- [ ] Providerflags zijn veilig uitgeschakeld; handmatige administratie bleef bruikbaar.
- [ ] Providerflags zijn pas na smoke opnieuw ingeschakeld.
- [ ] Geïsoleerde restore-drill gebruikt een snapshot jonger dan 24 uur en voltooit binnen vier uur; afzonderlijk providerbewijs toont managed production-RPO.
- [ ] Applicatierollback bewijst kandidaat → actuele productionrelease → kandidaat. Tijdens de eerste overgang is de signed legacy-adoptierun/hash onderdeel van het bewijs.
- [ ] Alle acht release-attestaties zijn uniek, maximaal 48 uur oud en aan exact dezelfde SHA/artifactdigest gebonden.
- [ ] Restorecontrole bewijst migraties, RLS, constraints en kernsmoke zonder providerverkeer.
- [ ] Incidenttabletops voor verloren staffaccount, gelekte QR, verdachte betaling en datalek zijn uitgevoerd.
- [ ] Keyrotatieprocedure voor Supabase, cron, Mollie, SendGrid en pepper-impact is beoordeeld.

Bewijs: `________________`

## 5. Eindbesluit

- [ ] Alle 28 E2E-scenario’s zijn groen.
- [ ] Alle security-, toegankelijkheids- en operationsgates zijn groen.
- [ ] Alle providerflows zijn in stagingtestmode uitgevoerd.
- [ ] Er is geen open blocker, critical of high bevinding.
- [ ] Exacte artefact-SHA, migratieset en canonversie zijn vastgelegd.

Besluit: `GO / NO-GO`
Open afwijkingen: `______________________________________________________________`
Releasebeheerder: `________________`
Securityreviewer: `________________`
Operationeel eigenaar: `________________`

Een GO voor stagingacceptatie is geen GO voor productie. Productie volgt de afzonderlijke gate in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).
