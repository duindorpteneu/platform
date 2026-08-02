# Stagingverificatie

Status: nog uit te voeren op een externe stagingomgeving
Canon: MVP v1.0, sectie 19 en 20.1
Artefact/commit-SHA: `________________`
Staging-URL: `________________`
Testrun (UTC): `________________`
Uitvoerder(s): `________________`

Deze verificatie gebruikt alleen fictieve gegevens en provider-testmodi. Elk scenario krijgt een bewijslink naar geautomatiseerde output, screenshot of geredigeerd operationeel record. Bewijs bevat geen e-mailadres, OTP, QR-token, cookie, key of volledige webhookbody.

## 1. Toelatingsvoorwaarden

- [ ] CI, lokale releasegate en [SECURITY_ACCEPTANCE.md](SECURITY_ACCEPTANCE.md) zijn groen op dezelfde commit-SHA.
- [ ] Staging en production zijn aantoonbaar gescheiden volgens [ENVIRONMENT_MATRIX.md](ENVIRONMENT_MATRIX.md).
- [ ] Alle migraties zijn op een lege stagingdatabase toegepast; fictieve seeddata is geladen.
- [ ] HTTPS, HSTS, CSP, secure cookies en no-store voor gevoelige responses zijn actief.
- [ ] De actieve Caddy 2.10+-configuratie bevat de route-specifieke request-bodycaps; de deploy-eindprobe heeft alle vier chunked routegroepen met proxy-`413` bewezen.
- [ ] Eén fictief account per staffrol heeft TOTP/AAL2; er is ook een geblokkeerd account.
- [ ] Er zijn fixtures voor één e-mail/één lid, één e-mail/drie leden, betaald, onbetaald, nalevering en dubbele uitgifteconcurrentie.
- [ ] Mollie staat in testmode en webhook gebruikt publiek HTTPS.
- [ ] De Mollie-acceptatie vindt een bestaand actief open stagingseizoen en `mollie_enabled=true`; het productschema retourneert voor alle vier verwijderde fixture-RPC's `404/PGRST202`.
- [ ] SendGrid-afzender/template en signed event webhook zijn staging-specifiek.
- [ ] Publieke en interne health, queue, webhook- en reconciliatiemonitoring zijn zichtbaar.
- [ ] Providerflags starten uit en worden alleen binnen de expliciete providerscenario’s aangezet.

## 2. Verplichte end-to-endscenario’s

### E2E-01 — Sportlinkimport

- [ ] Upload één CSV met een nieuw lid, bestaand lid, dubbel e-mailadres en ongeldige rij.
- [ ] Preview onderscheidt create/update/invalid en toont geen uitvoering van formuleachtige celinhoud.
- [ ] Commit verwerkt uitsluitend geldige rijen volgens canon, blijft transactioneel en legt één batchaudit vast.
- [ ] Herhaling maakt geen dubbel lid op relatienummer.

Verwacht canoniek resultaat: correcte preview; commit alleen geldige rijen; batch gelogd.
Bewijs: `________________`

### E2E-02 — Eén e-mail, één lid

- [ ] Vraag met een bekend fictief e-mailadres een zescijferige code aan.
- [ ] Gebruik de code binnen tien minuten exact één keer.
- [ ] Het enige kandidaat-lid wordt expliciet/direct gekoppeld en de eigen lidkaart is zichtbaar.

Verwacht canoniek resultaat: code tien minuten geldig; lid gekoppeld; dashboard zichtbaar.
Bewijs: `________________`

### E2E-03 — Eén e-mail, drie leden

- [ ] Vraag met het gedeelde fictieve e-mailadres een code aan.
- [ ] Selectiescherm toont precies de drie kandidaten zonder automatische koppeling.
- [ ] Kies één of meer leden en voeg een overgeslagen kandidaat later via “Lid toevoegen” toe.
- [ ] Elk lid behoudt eigen order, bedrag, status en QR.

Verwacht canoniek resultaat: selectiescherm; één of meer kiezen; overige later toevoegen.
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
- [ ] Controleer één immutable paid-record, paid order, actieve QR en één mailjob.
- [ ] Controleer dat de externe target-locked SQL-runner geen globale instelling of duurzame fixturetabel maakt en dat alle run-unieke ouder-, lid-, order-, payment-, QR-, e-mail- en eventfixtures in `finally` zijn verwijderd; het testmode-providerrecord blijft zonder PII in het stagingprofiel staan.

Verwacht canoniek resultaat: payment paid, QR actief, mailjob aangemaakt.
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
- [ ] Controleer één lokale statuswijziging, één auditketen en geen dubbele e-mail- of QR-actie.

Verwacht canoniek resultaat: één statuswijziging; geen dubbele mail/QR.
Bewijs: `________________`

### Mollie-refundacceptatie

- [ ] Start via de Mollie test-API een volledige refund van de door E2E-05 betaalde testbetaling; het portaal biedt bewust geen refundknop.
- [ ] Wacht tot Mollie `amountRefunded` voor het volledige EUR-bedrag retourneert en lever het provider-ID via de publieke stagingwebhook af.
- [ ] Controleer paymentstatus `refunded`, één refundevent/audit, nul actieve QR-codes, geen uitgifterecht en geen tweede betalingsmail.
- [ ] Bewijs dat de workflow uitsluitend de `test_`-key en het verwachte stagingprofiel gebruikte en geen checkout-URL, cookie, key, e-mailadres of webhookbody logde of als artefact opsloeg.

Verwacht canoniek resultaat: refund zichtbaar; actieve QR ingetrokken; geen nieuw uitgifterecht.
Bewijs: `________________`

### E2E-08 — Exacte kasbetaling

- [ ] Registreer als beheerder/kledingcommissie kas voor een open order.
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

- [ ] Scan een geldige QR voor een onbetaalde order.
- [ ] Uitgifterol ziet alleen minimale operationele data en kan geen regel voltooien.
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
- [ ] Exporteer als beheerder/kledingcommissie CSV en XLSX met server-side filters.
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

## 3. Security-, browser- en toegankelijkheidsgates

- [ ] Anoniem, ouder, beheerder, kledingcommissie en uitgifte zijn tegen alle gevoelige routes getest.
- [ ] State-changing cookieauthrequests zonder/onjuiste CSRF, Origin of Host worden vóór domeinactie geweigerd.
- [ ] OTP-request/verify, Mollie-create, QR-lookup, zoeken en export retourneren aantoonbaar een begrensde 429/neutrale response.
- [ ] Upload controleert requestgrootte, CSV-extensie, MIME, inhoud, rij/kolom/cellimieten en binaire/polyglotinput.
- [ ] CSP bevat minimaal `default-src`, `base-uri`, `object-src` en `frame-ancestors`; productie bevat geen `unsafe-eval`.
- [ ] HSTS, nosniff, referrer- en permissionspolicy gelden voor pagina, API, redirect en foutresponse.
- [ ] Logs en auditbewijs bevatten correlation-id maar geen secrets, tokens, e-mails, namen of webhookbody.
- [ ] Chrome, Edge en Safari huidig/vorig zijn gedekt; mobiele Safari/Chrome voor leden.
- [ ] Viewports: leden vanaf 360 px, uitgifte vanaf 768 px, backoffice op 1280 px.
- [ ] Kernflows zijn volledig per toetsenbord uitvoerbaar; focus zichtbaar; labels/status/fouten screenreaderbruikbaar.
- [ ] Contrast voldoet WCAG 2.2 AA en status is niet alleen kleur.
- [ ] Reduced-motionvoorkeur schakelt niet-essentiële motion uit.

Bewijs: `________________`

## 4. Operations- en herstelgates

- [ ] E-mailworker iedere minuut en dagelijkse retentiejob zijn twee cycli gevolgd.
- [ ] Interne health toont queue, stale/failed jobs, webhookmismatches en betaalreconciliatie zonder PII.
- [ ] Providerflags zijn veilig uitgeschakeld; handmatige administratie bleef bruikbaar.
- [ ] Providerflags zijn pas na smoke opnieuw ingeschakeld.
- [ ] Geïsoleerde restore-drill gebruikt een back-up jonger dan 24 uur en herstelt binnen vier uur.
- [ ] Restorecontrole bewijst migraties, RLS, constraints en kernsmoke zonder providerverkeer.
- [ ] Incidenttabletops voor verloren staffaccount, gelekte QR, verdachte betaling en datalek zijn uitgevoerd.
- [ ] Keyrotatieprocedure voor Supabase, cron, Mollie, SendGrid en pepper-impact is beoordeeld.

Bewijs: `________________`

## 5. Eindbesluit

- [ ] Alle achttien E2E-scenario’s zijn groen.
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
