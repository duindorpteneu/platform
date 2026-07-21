# Operationsrunbook

Status: uitvoerbare baseline tot en met stagingverificatie
Doelwaarden: RPO maximaal 24 uur, RTO maximaal 4 uur

Dit runbook gebruikt geen productiecredentials en geeft geen toestemming voor productieacties. Leg vóór staging de namen en bereikbaarheidsgegevens van releasebeheerder, technisch incidentleider en privacycontact vast in een afgeschermd operationeel register, niet in Git.

## 1. Dagelijkse operationele controle

### Health

- `GET /api/health` is de publieke liveness/readinesscontrole. Verwacht `200` met uitsluitend `status`, `service`, `environment` en de volledige `revision`. Een `503` of `degraded` alarmeert, maar bevat geen database- of persoonsgegevens.
- `GET /api/internal/health` vereist `Authorization: Bearer <CRON_SECRET>` en retourneert uitsluitend operationele tellingen: e-mailqueue, stale/failed jobs, betaalreconciliatie en recente webhookmismatches.
- Beide responses moeten `Cache-Control: no-store` gebruiken. Bewaar nooit de bearerheader in monitorlogs.

Voorbeeld vanaf een beveiligde runner:

```bash
curl --fail --silent --show-error "${APP_BASE_URL}/api/health"
curl --fail --silent --show-error \
  --header "Authorization: Bearer ${CRON_SECRET}" \
  "${APP_BASE_URL}/api/internal/health"
```

Alarmeer direct bij:

- publieke health twee opeenvolgende minuten `degraded` of onbereikbaar;
- één of meer e-mailjobs langer dan 15 minuten in `processing`;
- één of meer definitief gefaalde e-mailjobs;
- één of meer betaalreconciliatieproblemen;
- één of meer webhookmismatches in 24 uur;
- scheduler die twee verwachte uitvoeringen mist;
- dagelijkse databaseback-up ouder dan 24 uur.

Leg incidenttijd, omgeving, commit-SHA, correlation-id, niet-PII foutcode en eigenaar vast. Kopieer geen requestbody, e-mailadres, OTP, QR-token, sessiecookie of providerkey naar logs of tickets.

### Schedulers

| Job | Route | Frequentie | Geldige uitkomst |
| --- | --- | --- | --- |
| E-mailworker | `POST /api/internal/jobs/email` | Iedere minuut | `200`; `paused` is alleen geldig wanneer de runtime- of databaseswitch voor e-mail uit staat |
| Retentie | `POST /api/internal/jobs/retention` | Dagelijks | `200` met alleen verwijderde aantallen |

Beide jobs gebruiken dezelfde omgevingsspecifieke `CRON_SECRET` via een bearerheader. De scheduler volgt redirects niet, logt de header niet en heeft een korte timeout. Een `401` betekent secret/configuratiemismatch; `5xx` betekent een operationeel incident.

Voor staging voert `.github/workflows/staging-operations.yml` de e-mailworker in vijf korte cycli per vijfminutenschedule uit en de retentiejob dagelijks. De workflow is uitsluitend aan de GitHub Environment `staging` gekoppeld. GitHub-schedules kunnen vertraagd starten en zijn daarom geen productie-scheduler; production vereist vóór ingebruikname een afzonderlijke, bewaakte scheduler die iedere minuut aantoonbaar uitvoert.

De retentiejob:

- verwijdert gebruikte/verlopen OTP-challenges uiterlijk na 24 uur;
- verwijdert rate-limit-events ouder dan 30 dagen;
- verwijdert oudersessies uiterlijk 30 dagen na expiratie of intrekking;
- verwijdert e-mailprovider-events ouder dan 12 maanden;
- verwijdert geen orders, betalingen, fulfilments of auditregels.

Uitgiftehistorie wordt minimaal twee volledige seizoenen behouden en daarna handmatig beoordeeld. Financiële administratie blijft zeven jaar wanneer fiscaal vereist. Audit blijft minimaal 24 maanden; betaalgerelateerde audit volgt financiële retentie.

## 2. E-mailqueue en vastgelopen jobs

1. Zet bij brede of onbegrepen storing `EMAIL_ENABLED=false` en deploy alleen die configuratiewijziging. Handmatige administratie blijft beschikbaar.
2. Controleer interne health en noteer alleen job-ID, status, attempt count, foutcode en timestamps.
3. Controleer SendGrid op provider-message-ID. Zoek niet op volledige inhoud en kopieer geen ontvanger naar het incidentdossier.
4. Een job in `processing` ouder dan 15 minuten is verdacht. Zet deze niet blind terug:
   - bij aantoonbare provideracceptatie: voorkom opnieuw verzenden en reconcilieer status;
   - bij aantoonbaar geen provideracceptatie: gebruik uitsluitend de beheer-/recoveryfunctie die claimtoken en idempotency bewaakt;
   - bij onzekerheid: laat de job staan, escaleer en voorkom een dubbele e-mail.
5. Controleer na recovery dat maximaal één providerbericht per job/idempotency key bestaat.
6. Los template-, afzender- of keyfout op, voer één gecontroleerde worker-run uit en controleer de tellingen.
7. Zet `EMAIL_ENABLED=true` pas terug na een staging-smoke met één fictieve ontvanger en groene health.

Een database-update buiten een geautoriseerde recoveryfunctie is geen normale herstelroute. Ontbreekt zo’n veilige recoveryfunctie, dan blijft handmatige wijziging geblokkeerd en is dit een releaseblokker.

## 3. Betaal- en webhookreconciliatie

1. Zet bij onbegrepen mismatches `MOLLIE_ENABLED=false`; kas/pinregistratie en bestaande administratie blijven intact.
2. Gebruik correlation-id, lokale payment-ID en providerpayment-ID. Log geen volledige webhookpayload.
3. Haal de actuele betaling server-side bij Mollie op en vergelijk valuta, exact bedrag, ordermetadata en lokale order.
4. Markeer een order nooit handmatig paid op basis van redirect, screenshot of webhookbody.
5. Bij bedrag-/metadata-afwijking blijft de order niet-paid en gaat deze naar handmatige review.
6. Replay dezelfde webhook gecontroleerd; er mag geen tweede statuswijziging, e-mail of QR-actie ontstaan.
7. Documenteer oorzaak en forward-fix. Zet Mollie pas weer aan na succesvolle testmodebetaling, webhook en reconciliatiecontrole.

## 4. Provider-safety switches

Mollie en e-mail gebruiken ieder twee onafhankelijke veiligheidslagen: de runtimeflags `MOLLIE_ENABLED` en `EMAIL_ENABLED` zijn de harde bovengrens, terwijl een beheerder de bijbehorende databaseswitch via Instellingen kan uitzetten. Providerverkeer is alleen toegestaan wanneer beide lagen expliciet aan staan. Andere featureflags zijn niet toegestaan.

Uitschakelen:

1. incidentleider besluit en noteert reden/tijd;
2. zet bij voorkeur eerst de databaseswitch via Instellingen uit; wijzig bij een brede storing of onbereikbare backoffice ook de runtimeflag in precies één omgeving;
3. deploy alleen wanneer de runtimeflag wijzigt, met dezelfde geteste artefact-SHA en zonder codewijziging;
4. controleer health en bevestig dat handmatige administratie beschikbaar blijft;
5. communiceer de operationele beperking.

Inschakelen:

1. onderliggende oorzaak is opgelost;
2. key, webhook, template/bedrag en provideromgeving zijn gecontroleerd;
3. staging-smoke en reconciliatie zijn groen;
4. vier-ogen-goedkeuring is vastgelegd;
5. zet eerst de databaseswitch aan; wijzig daarna zo nodig de runtimeflag, deploy en monitor minimaal één volledige job-/webhookcyclus.

## 5. Back-up en geïsoleerde restore-oefening

### Back-upbeleid

- Productiondatabase: dagelijkse beheerde back-up; succesvolle back-up maximaal 24 uur oud.
- Staging en production hebben afzonderlijke back-upsets en toegangsrechten.
- Maak vóór iedere risicovolle productiemigratie een herstelpunt en bevestig dat het leesbaar is.
- Back-ups zijn versleuteld, alleen toegankelijk voor benoemde beheerders en worden nooit in deze repository of op een werkstation opgeslagen.
- Applicatieartefact, commit-SHA, migratieversie en omgevingsconfiguratie zonder secretwaarden horen bij het herstelbewijs.

### Restore-drill

Voer vóór eerste productie en daarna periodiek een gedateerde oefening uit. Start hiervoor handmatig de GitHub-workflow `Staging backup and isolated restore drill` met de volledige SHA die aantoonbaar op staging staat en bevestiging `STAGING-RESTORE`. De workflow draait op een tijdelijke GitHub-hosted runner, zodat de gedeelde applicatie-VPS en Castivo niet worden benaderd.

1. De workflow valideert het vaste stagingdomein, de stagingprojectref, databasehost, bevestiging en volledige release-SHA. De publieke healthcheck moet exact dezelfde SHA rapporteren.
2. De RTO-klok start vóór de dump. PostgreSQL 17 maakt een verse logische stagingback-up onder `RUNNER_TEMP`; het bestand heeft mode `0600` en wordt nooit als artifact geüpload.
3. De back-up wordt hersteld naar een run-unieke PostgreSQL 17-container zonder hostpoort, Caddy-route, extern netwerk, permanente volumes of providerconfiguratie.
4. De verificatie bewijst uitsluitend PostgreSQL-majorversie, migratieversies, constrainttotalen, RLS-telling en geaggregeerde aantallen per hoofdentiteit. Rijdata en persoonsgegevens komen niet in logs of artifacts.
5. De workflow faalt wanneer de verse snapshot bij afronding ouder dan 24 uur is, de totale oefening langer dan vier uur duurt, constraints ongeldig zijn of het herstel onvolledig is.
6. Een `always()`-stap verwijdert de run-specifieke containers, anonieme volumes, dump en ruwe verificatie. Alleen het geredigeerde JSON-bewijs blijft veertien dagen beschikbaar.

Deze logische oefening bewijst het technische dump-/herstelpad en de gemeten RPO/RTO voor de verse staging-snapshot. Zij vervangt niet de afzonderlijke controle dat de dagelijkse beheerde productionback-up maximaal 24 uur oud is. Een productieherstel blijft een expliciet changeproces met een geïsoleerde restorebestemming.

Een drill is mislukt wanneer de back-up ouder dan 24 uur is, herstel langer dan vier uur duurt, providerverkeer mogelijk is, integriteitscontroles falen of credentials/data buiten de geïsoleerde omgeving terechtkomen.

## 6. Incidentprocedures

### Verloren of gecompromitteerd staffaccount

1. Beheerder blokkeert het staffprofiel via de beheerfunctie en trekt actieve Auth-sessies in; voer geen directe tabelmutatie uit.
2. Controleer dat AAL1/AAL2 en bestaande sessies direct geen staffdata meer krijgen.
3. Controleer auditacties van het account op ongebruikelijke exports, betalingen, QR-rotaties en uitgiftes.
4. Roteer accountcredentials/TOTP door een nieuw persoonlijk accountproces; herstel geen gedeeld account.
5. Bij mogelijke secretblootstelling volgt keyrotatie volgens hoofdstuk 7.

Als blokkeren en sessie-intrekking niet zonder database-ingreep beschikbaar zijn, is dit vóór productie een releaseblokker.

### Gelekte QR-code

1. Zoek het lid/order via de geautoriseerde backoffice, niet via het token in logs.
2. Roteer de QR met verplichte reden; dezelfde order en uitgiftehistorie blijven bestaan.
3. Bewijs dat de oude QR ongeldig is en de nieuwe QR alleen na geldige betaling werkt.
4. Verstuur de nieuwe QR gecontroleerd; verwijder een gelekte afbeelding uit onbevoegde kanalen waar mogelijk.
5. Controleer audit en recente uitgiftes op misbruik.

### Verdachte betaling

1. Schakel zo nodig `MOLLIE_ENABLED=false`.
2. Vergelijk lokale immutable paymentrecord, orderbedrag, valuta, metadata en actuele Molliestatus.
3. Geef niet uit zolang paid niet server-side exact is bevestigd of wanneer een reconciliatieprobleem bestaat.
4. Bewaar audit/paymentrecord; corrigeer nooit door geschiedenis te overschrijven.
5. Escaleer mogelijke fraude naar de penningmeester/incidentleider en documenteer uitsluitend noodzakelijke identifiers.

### Datalek

1. Stop de blootstelling: blokkeer account, roteer betrokken QR/secrets en schakel relevante providerflag uit.
2. Bewaar geredigeerd bewijs en correlation-ids; wijzig of verwijder audit niet.
3. Bepaal welke gegevens, personen, periode en systemen geraakt zijn.
4. Informeer direct privacycontact en bestuur. Beoordeel melding aan Autoriteit Persoonsgegevens en betrokkenen binnen de geldende termijn; leg besluit en tijdlijn vast.
5. Herstel via een geteste forward-fix, controleer toegang en monitor herhaling.
6. Sluit pas na oorzaak-, impact- en preventiereview.

## 7. Keyrotatie

Algemene volgorde: nieuwe key maken met minimale rechten, applicatie/scheduler atomair omschakelen, smoke uitvoeren, oude key intrekken, health controleren en rotatiedatum vastleggen zonder keywaarde.

- `SUPABASE_SECRET_KEY`: roteer in één omgeving, werk appsecret bij, controleer health/jobs, trek oude key in.
- `CRON_SECRET`: maak nieuw secret, wijzig app en scheduler in hetzelfde changevenster, bewijs eerst `401` met oude en daarna succes met nieuwe waarde.
- Mollie: providerflag uit, nieuwe omgevingsjuiste key plaatsen, testmode-smoke/reconciliatie, oude key intrekken, pas daarna flag aan.
- SendGrid: e-mailflag uit, nieuwe minimaal bevoegde key plaatsen, één fictieve testjob, oude key intrekken, queue monitoren.
- `PARENT_TOKEN_PEPPER`: een directe vervanging maakt bestaande sessie-/QR-hashes onbruikbaar. Roteer alleen met een expliciet plan voor sessie-intrekking en QR-heruitgifte of geteste dual-peppermigratie. Een ongecoördineerde wijziging is verboden.
- Webhookverificatiesleutels: accepteer overlap alleen wanneer de implementatie dat expliciet ondersteunt; bewijs oude/nieuwe handtekening en verwijder de oude na het changevenster.

## 8. Forward-fix en herstel van releases

- Pas database-migraties vóór de applicatie toe.
- Wijzig of verwijder een toegepaste migratie nooit.
- Bij een schemafout: providers uit indien relevant, nieuwe additieve forward-fixmigratie maken, lokaal en staging testen, back-up bevestigen, migratie uitvoeren en smoke herhalen.
- Een approllback mag alleen wanneer het herstelde schema achterwaarts compatibel is. Anders blijft de huidige app staan en volgt forward-fix.
- Destructieve schemawijzigingen vereisen canonieke noodzaak, back-up en apart changebesluit; zij horen niet in een spoedfix.
- Releasebewijs bevat commit-SHA, migraties, back-uptijd, health, smoke, beslisser en eventuele afwijking.

## 9. Afsluitcriteria operationeel incident

- oorzaak en impact zijn vastgesteld;
- onveilige toegang/provideractie is gestopt;
- data-integriteit en audit zijn gecontroleerd;
- forward-fix en relevante E2E/securitytest zijn groen;
- health en scheduler zijn minimaal één cyclus stabiel;
- secrets zijn waar nodig geroteerd;
- betrokkenen/toezichthouder zijn waar nodig geïnformeerd;
- post-incidentactie heeft eigenaar en deadline.
