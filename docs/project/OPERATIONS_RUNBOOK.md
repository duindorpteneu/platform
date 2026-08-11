# Operationsrunbook

Status: uitvoerbare baseline tot en met stagingverificatie
Doelwaarden: RPO maximaal 24 uur, RTO maximaal 4 uur

Dit runbook gebruikt geen productiecredentials en geeft geen toestemming voor productieacties. Leg vóór staging de namen en bereikbaarheidsgegevens van releasebeheerder, technisch incidentleider en privacycontact vast in een afgeschermd operationeel register, niet in Git.

## 1. Dagelijkse operationele controle

### Health

- `GET /api/health` is de publieke liveness/readinesscontrole. Verwacht `200` met uitsluitend `status`, `service`, `environment` en de volledige `revision`. Een `503` of `degraded` alarmeert, maar bevat geen database- of persoonsgegevens.
- `GET /api/internal/health` vereist `Authorization: Bearer <CRON_SECRET>` en retourneert uitsluitend operationele tellingen: e-mailqueue, onzekere/stale/failed jobs, recente afleverfouten, scheduler-runstatus, betaalreconciliatie, recente webhookmismatches en geaggregeerde importstaging. Groen is HTTP `200` met `status: "healthy"`; een operationeel probleem retourneert HTTP `503` met `status: "degraded"`, zodat `curl --fail` en externe monitors dit niet als groen behandelen.
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
- één of meer e-mailjobs met status `delivery_uncertain`;
- één of meer definitief gefaalde e-mailjobs;
- één of meer recente `bounced`, `dropped` of `failed` SendGrid-events;
- één of meer betaalreconciliatieproblemen;
- één of meer webhookmismatches in 24 uur;
- één of meer verlopen versleutelde importuploads na twee retentiecycli;
- scheduler die twee verwachte uitvoeringen mist;
- dagelijkse databaseback-up ouder dan 24 uur.

Leg incidenttijd, omgeving, commit-SHA, correlation-id, niet-PII foutcode en eigenaar vast. Kopieer geen requestbody, e-mailadres, OTP, QR-token, sessiecookie of providerkey naar logs of tickets.

### Reverse-proxy bodylimieten

Het immutable app-image luistert op containerpoort `3000` met
`scripts/runtime/body-limit-gateway.mjs`. Deze minimale Node-reverse-proxy
gebruikt geïsoleerde routegroeppools met samen maximaal `37632000` bytes,
begrenst tijd en fragmentatie en stuurt een body
pas na volledige validatie door naar Next.js op uitsluitend
`127.0.0.1:3001`. Dezelfde routegroepen en decimale caps uit
`deploy/edge-body-probe-contract.json` gelden in staging en productie:
standaard-API `128000`, bulkmail `384000`, SendGrid-webhook `2000000` en
Sportlink-import `12000000` bytes. De fijnmazigere routepolicy blijft daarna
zelfstandig parser-, tijd- en fragmentatiegrenzen afdwingen.

De Caddy 2.10+-configuratie in
`deploy/caddy/duindorp-tenueportaal.caddy.example` is een optionele aanvullende
hostgrens. Repositoryworkflows lezen of wijzigen de gedeelde host-Caddy niet.
Wanneer hostbeheer de referentie afzonderlijk toepast, moet het die eerst
valideren en dezelfde niet-overlappende routegroepen behouden.

Iedere staging- en productiondeployment voert na de publieke healthcheck
`scripts/deploy/check-edge-body-limits.mjs` uit. De immutable runtimegateway
moet de cap altijd handhaven; een eventuele Caddygrens mag eerder afwijzen.
Caddy 2.10 handhaaft `request_body` tijdens het lezen en een upstream die al op
headers antwoordt kan daarom geen chunked limiet bewijzen. De gate verstuurt
per routegroep twee
side-effectvrije verzoeken naar het bestaande pad. Een kortlevend,
route-/host-/omgeving-/release-/bytegebonden HMAC-bewijs, afgeleid van
`CRON_SECRET`, laat uitsluitend de no-op applicatiebranch de body streamend
weggooien. Het secret zelf wordt niet verstuurd.

Exact de decimale gatewaygrens (`128000`, `384000`, `2000000` of `12000000`
bytes) moet `204` met `x-duindorp-edge-body-probe-result:
application-reached` geven. Grens plus één moet `413` zonder die marker geven.
De applicatiebranch retourneert zelf nooit `413`, raakt geen auth, parser,
database, audit, import, mail of provider en weigert ieder partieel, verlopen,
gecomprimeerd of van `Content-Length` voorzien bewijs vóór body-read. De app
canoniseert met de publieke `APP_BASE_URL` en eist dat `Host`, de enkelvoudige
`X-Forwarded-Host` en `X-Forwarded-Proto` daarmee overeenkomen; de interne
Next-runtime-URL is alleen gezaghebbend voor pad en query. Next' middlewareclone
is exact begrensd op `12000001` bytes, zodat ook de grootste controlebody niet
wordt afgekapt; de runtimegateway, optionele Caddy en routepolicy blijven
onafhankelijke grenzen. Alleen deze combinatie is groen. De probe logt uitsluitend
routegroep, fase en status; logredactie wist nonce en handtekening defensief.

### Schedulers

| Job | Route | Frequentie | Geldige uitkomst |
| --- | --- | --- | --- |
| E-mailworker | `POST /api/internal/jobs/email` | Iedere minuut | `200` met `status: "processed"`; `status: "paused"` is alleen geldig wanneer de runtime- of databaseswitch voor e-mail uit staat |
| Retentie | `POST /api/internal/jobs/retention` | Bij schedulerstart en daarna uiterlijk iedere vijf minuten | `200` met `status: "completed"` en alleen verwijderde aantallen |

Beide jobs gebruiken dezelfde omgevingsspecifieke `CRON_SECRET` via een bearerheader. De scheduler volgt redirects niet, logt de header niet en heeft een korte timeout. Een `401` betekent secret/configuratiemismatch; `5xx` betekent een operationeel incident.

De geharde `scheduler`-service draait in ieder omgevingsspecifiek Composeproject zonder hostpoort en roept de app uitsluitend via het interne netwerk aan. De vroegere GitHub-cron is verwijderd; `.github/workflows/staging-operations.yml` blijft alleen als handmatige diagnose beschikbaar. Productionruntime vereist bovendien een onafhankelijke geheime `OPERATIONS_HEARTBEAT_URL`: uitsluitend een volledig gezonde cyclus verstuurt een ping, zodat VPS-, Caddy-, netwerk- en scheduleruitval extern alarmeert. Zie `docs/deployment/production-operations.md`.

De retentiejob:

- verwijdert gebruikte/verlopen OTP-challenges uiterlijk na 24 uur;
- verwijdert rate-limit-events ouder dan 30 dagen;
- verwijdert oudersessies uiterlijk 30 dagen na expiratie of intrekking;
- verwijdert e-mailprovider-events ouder dan 12 maanden;
- verwijdert voltooide operation-runrecords ouder dan 90 dagen, maar behoudt vastgelopen `running`-records voor onderzoek;
- verwijdert versleutelde ruwe importuploads op hun per-upload expiry (standaard 24 uur, configureerbaar 1–72 uur) en behoudt alleen PII-vrije batch-/auditmetadata;
- verwijdert geen orders, betalingen, fulfilments of auditregels.

Roteer `IMPORT_STAGING_ENCRYPTION_KEY` alleen wanneer geen actieve raw uploads bestaan. De deploy voert na migraties en vóór appactivatie de service-only `assert_dynamic_import_staging_key`-gate uit met uitsluitend een SHA-256-fingerprint; een andere of ontbrekende key blokkeert zolang een niet-verlopen upload nog decryptie vereist. Veilige rotatie:

1. zet eerst de databaseflag `dynamic_import_v2=false` en daarna `DYNAMIC_IMPORT_ENABLED=false`, zodat geen nieuwe upload wordt aangenomen; de duurzame cutovermarker blijft daarbij staan en het legacy-importpad blijft dus gesloten;
2. laat bestaande uploads verwerken of wacht tot de vijfminutenretentie alle expiraties heeft verwijderd; voer geen ongeautoriseerde purge uit;
3. bevestig via geaggregeerde interne health dat `importStaging.pending=0` en `expired=0`;
4. wijzig de omgevingsunieke key uitsluitend in de beschermde secretstore;
5. deploy hetzelfde goedgekeurde artefact; de sleutelgate moet vóór runtimeactivatie groen zijn;
6. activeer pas daarna eerst de databasepoort en vervolgens de runtimepoort.

Cleanup en health blijven actief wanneer import uit staat. De databasepoort sluit bij v2-cutover ook de legacy preview- en commit-RPC af; het terugzetten van alleen de runtimeflag kan het oude pad daarom niet heropenen.

Uitgiftehistorie wordt minimaal twee volledige seizoenen behouden en daarna handmatig beoordeeld. Financiële administratie blijft zeven jaar wanneer fiscaal vereist. Audit blijft minimaal 24 maanden; betaalgerelateerde audit volgt financiële retentie.

## 2. E-mailqueue en vastgelopen jobs

1. Zet bij brede of onbegrepen storing `EMAIL_ENABLED=false` en deploy alleen die configuratiewijziging. Handmatige administratie blijft beschikbaar.
2. Controleer interne health en noteer alleen job-ID, status, attempt count, foutcode en timestamps.
3. Controleer SendGrid op provider-message-ID. Zoek niet op volledige inhoud en kopieer geen ontvanger naar het incidentdossier. Gebruik als bewijsreferentie uitsluitend een niet-persoonlijke provider- of ticketreferentie met letters, cijfers en `._:/-`.
4. Een job in `processing` ouder dan 15 minuten is verdacht. Zet deze niet blind terug:
   - bij aantoonbare provideracceptatie: een geldige signed SendGrid-eventwebhook reconcilieert `processing`/`delivery_uncertain` automatisch zonder resend; ontbreekt die, gebruik dan als beheerder met AAL2 in **E-mailcentrum → Verzending → Bewijs beoordelen** de optie **Geaccepteerd — niet opnieuw sturen**, met providerbericht-ID en bewijsreferentie;
   - bij aantoonbaar geen provideracceptatie: gebruik uitsluitend dezelfde AAL2-beheeractie **Niet geaccepteerd — opnieuw inplannen**, met bewijsreferentie en expliciete attestatie;
   - bij onzekerheid: laat de job staan, escaleer en voorkom een dubbele e-mail.
5. Vernieuw de pagina wanneer optimistic concurrency meldt dat de job intussen is gewijzigd; beoordeel het actuele providerbewijs opnieuw en herhaal nooit blind hetzelfde besluit.
6. Controleer na recovery dat maximaal één providerbericht per job/idempotency key bestaat en dat precies één `email.job.recovered.sent`- of `email.job.recovered.retry`-auditregel is toegevoegd zonder ontvanger of bewijswaarde.
7. Los template-, afzender- of keyfout op, voer één gecontroleerde worker-run uit en controleer de tellingen.
8. Zet `EMAIL_ENABLED=true` pas terug na een staging-smoke met één fictieve ontvanger en groene health.

Een database-update buiten `app.recover_stale_email_job` is geen herstelroute. Time-outs, netwerkfouten, provider-5xx en een succesvolle HTTP-response zonder providerbericht-ID worden altijd `delivery_uncertain` en mogen nooit automatisch opnieuw worden verzonden. Alleen een expliciete HTTP `429` geldt als veilig retrybare providerweigering.

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
2. De technische drillklok start vóór de dump. PostgreSQL 17 maakt een verse logische stagingback-up onder `RUNNER_TEMP`; het bestand heeft mode `0600` en wordt nooit als artifact geüpload.
3. De back-up wordt hersteld naar een run-unieke PostgreSQL 17-container zonder hostpoort, Caddy-route, extern netwerk, permanente volumes of providerconfiguratie.
4. De verificatie bewijst uitsluitend PostgreSQL-majorversie, migratieversies, constrainttotalen, RLS-telling en geaggregeerde aantallen per hoofdentiteit. Rijdata en persoonsgegevens komen niet in logs of artifacts.
5. De workflow faalt wanneer de verse snapshot bij afronding ouder dan 24 uur is, de totale oefening langer dan vier uur duurt, constraints ongeldig zijn of het herstel onvolledig is.
6. Een `always()`-stap verwijdert de run-specifieke containers, anonieme volumes, dump en ruwe verificatie. Alleen het geredigeerde JSON-bewijs blijft veertien dagen beschikbaar.

Deze logische oefening bewijst de leeftijd van de gebruikte verse snapshot en
de gemeten technische restoreduur. Zij bewijst uitdrukkelijk geen managed
backup-RPO. Controleer afzonderlijk dat de dagelijkse beheerde
productionback-up maximaal 24 uur oud is en leg providerbewijs vast. Een
productieherstel blijft een expliciet changeproces met een geïsoleerde
restorebestemming.

Een drill is mislukt wanneer de back-up ouder dan 24 uur is, herstel langer dan vier uur duurt, providerverkeer mogelijk is, integriteitscontroles falen of credentials/data buiten de geïsoleerde omgeving terechtkomen.

### Geautoriseerde staging-domeinopschoning

Gebruik uitsluitend de handmatige workflow `Staging domain cleanup`. Deze procedure mag nooit tegen production worden gebruikt en vervangt geen migratie, seed of algemene databasereset.

1. Deploy eerst exact de beoogde `main`-SHA naar staging. Zet de runtime- én databaseswitches voor Mollie, e-mail en dynamische import uit.
2. Start modus `dry-run` met de live SHA en bevestiging `STAGING-CLEANUP-DRY-RUN`. Controleer het PII-vrije artifact met tellingen voor exact 100 wistabellen, 28 behouden tabellen en alle veiligheidsblockers.
3. Modus `apply` vereist bevestiging `STAGING-CLEANUP-APPLY`, exact origin `https://staging-duindorp.dgwebservices.nl`, exact Supabase-project `dxbdjtbyghsovlrdcwcr` en secret `STAGING_CLEANUP_BACKUP_PASSPHRASE`. De bekende production-ref en iedere andere project-ref worden geweigerd.
4. De stagingrunner controleert Rootless Docker, runtimepad, Composeproject, actieve image en live SHA en stopt uitsluitend `app` en `scheduler` van `duindorpteneu-staging`. De deploylock en workflowconcurrency voorkomen overlap met deployment en Mollieacceptatie.
5. PostgreSQL 17 maakt een verse dump van `app`, `private`, `public`, `auth` en `supabase_migrations`. De dump wordt lokaal AES-256 versleuteld, weer gedecrypteerd en in een container met `--network none` volledig hersteld en geverifieerd vóór de eerste datamutatie.
6. De encrypted dump plus een PII-vrije prepared-state worden eerst als immutable artifact geüpload. Alleen een succesvolle upload levert het artifact-ID waarmee de applyfase verder mag. Apply stopt staging opnieuw en weigert wanneer de actuele operationele SHA-256-statedigest afwijkt van de geüploade back-up.
7. De transactie neemt `ACCESS EXCLUSIVE`-locks op de vaste 100-tabellenallowlist, vergelijkt onder lock opnieuw dezelfde digest en gebruikt één `TRUNCATE ... RESTART IDENTITY` zonder `CASCADE`.
8. `auth.*`, `app.staff_profiles`, seizoenen, instellingen, templates, branding, reminderregels/-runs, audit, featureflags, migratie-/operationele ledgers, staffsessies en supplierconfiguratie blijven behouden. De audit groeit met exact één PII-vrije `staging.domain_cleanup.completed`-regel.
9. Iedere doelrij moet na commit nul zijn. Staff-/Auth-ID's, beheerderstatus, configuratiedigest, constraints en migratieledger moeten exact gelijk blijven. Daarna worden exact dezelfde appimage en scheduler herstart en opnieuw gezond verklaard.
10. Bewaar het encrypted back-upartifact en geredigeerde bewijs dertig dagen. De decryptiesleutel blijft uitsluitend in het afgeschermde stagingenvironment. Een mislukking vóór commit rolt atomair terug; na commit is herstel alleen vanuit dit artifact toegestaan.

Verwijder of wijzig nooit de allowlist om een driftfout te omzeilen. Een nieuwe `app`- of `private`-tabel vereist eerst een bewuste preserve/wipebeslissing, testaanpassing en review.

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
- `PARENT_TOKEN_PEPPER`: een directe vervanging maakt bestaande OTP-/oudersessiehashes onbruikbaar. Pauzeer ouderlogin, trek bestaande oudersessies gecontroleerd in, wijzig de unieke omgevingskey en bewijs opnieuw OTP plus sessie-intrekking.
- QR-keyring:
  1. plaats de bestaande current key/version tijdelijk als `QR_TOKEN_PREVIOUS_PEPPER` en `QR_TOKEN_PREVIOUS_PEPPER_VERSION`;
  2. plaats een nieuwe unieke `QR_TOKEN_PEPPER` met de volgende `QR_TOKEN_PEPPER_VERSION`, deploy hetzelfde artifact en controleer dat current/previous verschillend en geldig zijn;
  3. roteer alle actieve locators gecontroleerd; oude locators en open grants worden daarbij ingetrokken en ouders krijgen alleen de nieuwe QR;
  4. verwijder de previous key pas wanneer interne health zowel `previousKeyActiveLocators=0` als `previousKeyOpenGrants=0` meldt. Een key mismatch, verwijdering vóór nul of hergebruik tussen omgevingen blokkeert release.
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
