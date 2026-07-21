# Omgevingsmatrix

Status: vereiste configuratie tot en met stagingverificatie
Canon: MVP v1.0, hoofdstuk 20

## Harde scheiding

| Onderdeel | Local | Staging | Production |
| --- | --- | --- | --- |
| Doel | Ontwikkeling en reproduceerbare lokale tests | Volledige acceptatie met fictieve data en echte provider-testmodi | Werkelijk gebruik door Duindorp SV |
| App-URL | `http://localhost:3100` | Eigen publieke HTTPS-hostnaam | Eigen publieke HTTPS-hostnaam, niet gelijk aan staging |
| App-runtime | Lokale Node-runtime | EU-regio of aantoonbaar privacygeschikte gelijkwaardige regio | Afzonderlijke EU-/privacygeschikte runtime |
| Supabase | Projectlokale Docker-stack `duindorp-tenueportaal-local` | Eigen Supabase-project in EU-regio | Ander Supabase-project in EU-regio |
| Databasegegevens | Uitsluitend fictieve seed-/testdata | Uitsluitend fictieve of aantoonbaar geanonimiseerde data | Werkelijke leden- en financiële data |
| Supabase Auth | Tijdelijke zelfopruimende testaccounts | Fictieve staffaccounts met TOTP/AAL2 | Persoonlijke medewerkersaccounts met TOTP/AAL2 |
| Mollie | Uit; mocks/contracttests | Testmode-account en publiek HTTPS-webhook | Afzonderlijke live key; pas na expliciete live gate |
| SendGrid | Uit; lokale mailopvang/mocks | Geverifieerd test-/sandboxpad en stagingconfiguratie | Afzonderlijke key, geverifieerd afzenderdomein |
| `MOLLIE_ENABLED` | `false` | `true` alleen tijdens provideracceptatie | Standaard `false` tot live gate is goedgekeurd |
| `EMAIL_ENABLED` | `false` | `true` alleen na afzender-/templatecontrole | `true` alleen na mail-smoke en operationele goedkeuring |
| Secrets | Alleen in niet-gecommitte `.env.local` | Staging-secretstore | Afzonderlijke production-secretstore |
| Back-up | Niet van toepassing op testdata; resetbaar | Back-up vóór risicovolle migratie en restore-oefening | Dagelijkse back-up; laatste succesvolle back-up jonger dan 24 uur |
| Logging | Lokale geredigeerde logs | Geredigeerd, correlation-id, scheduler-health optioneel extern bewaakt | Afzonderlijke retentie/toegang, geredigeerd en verplicht via externe dead-man-switch bewaakt |
| Deploy | Handmatig lokaal | Na merge via `Deploy staging` | Alleen expliciete `Promote production`, dezelfde stagingartefacten en environmentapproval |

Staging en production delen nooit projecten, databases, Auth-users, service-role keys, peppers, cronsecrets, Mollie-keys, SendGrid-keys, webhooks of logbestemmingen. Productiedata gaat niet naar staging zonder gedocumenteerde anonimisering en goedkeuring van de privacyverantwoordelijke.

## Configuratiecontract

| Variabele | Classificatie | Local | Staging en production |
| --- | --- | --- | --- |
| `APP_BASE_URL` | Niet geheim | Exact de eigen origin | Publieke HTTPS-origin zonder pad |
| `NEXT_PUBLIC_SUPABASE_URL` | Publiek | Lokale API op poort 54329 | URL van uitsluitend het eigen project |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Publiek maar omgevingsgebonden | Lokale key | Publishable key van uitsluitend het eigen project |
| `SUPABASE_SECRET_KEY` | Hoog geheim, server-only | Lokale secret key | Unieke secret/service-role key in secretstore |
| `SUPABASE_JWKS` | Publiek maar omgevingsgebonden | Optioneel; lokale JWKS of tijdelijke lokale endpointfallback | Verplicht; gevalideerde ES256/P-256 keyset van exact het eigen project, zonder runtime-netwerkafhankelijkheid |
| `PARENT_TOKEN_PEPPER` | Hoog geheim, server-only | Uniek, minimaal 32 tekens | Uniek per omgeving; rotatie vereist sessie-/QR-plan |
| `CRON_SECRET` | Hoog geheim, server-only | Uniek, minimaal 16 tekens | Uniek per omgeving en uitsluitend scheduler-to-app |
| `OPERATIONS_HEARTBEAT_URL` | Hoog geheim, server-only | Leeg | Unieke externe HTTPS dead-man-switch; verplicht in production en nooit gelogd |
| `MOLLIE_ENABLED` | Harde runtime-safety switch | `false` | Alleen `true` na de bijbehorende gate; database-instelling moet daarnaast aan staan |
| `MOLLIE_API_KEY` | Hoog geheim, server-only | Leeg | Testkey in staging, afzonderlijke live key in production |
| `EMAIL_ENABLED` | Harde runtime-safety switch | `false` | Alleen `true` na de bijbehorende gate; database-instelling moet daarnaast aan staan |
| `SENDGRID_API_KEY` | Hoog geheim, server-only | Leeg | Unieke minimaal bevoegde Mail Send-key |
| `SENDGRID_API_BASE_URL` | Configuratie | `https://api.sendgrid.com` | Gebruik `https://api.eu.sendgrid.com` uitsluitend voor een EU-regional subuser |
| `SENDGRID_FROM_EMAIL` | Configuratie | Leeg | Geverifieerd afzenderadres van de omgeving |
| `SENDGRID_REPLY_TO_EMAIL` | Configuratie | Leeg | Operationeel beheerd antwoordadres |
| `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY` | Verificatiesleutel | Leeg | Publieke verificatiesleutel van de omgeving |

Geen enkele geheime variabele krijgt een `NEXT_PUBLIC_`-prefix. Secrets staan niet in GitHub-workflowtekst, screenshots, tickets, logs of testbewijs. De repository bevat alleen lege voorbeelden.

## Staging-aanmaak

Voor de eerste stagingdeploy legt de releasebeheerder buiten Git vast:

1. eigenaar en EU-regio van app en Supabase;
2. staginghostnaam, projectreferentie en secretstore-locatie;
3. technische beheerder, incidentcontact en privacycontact;
4. back-upmogelijkheid en gekozen geïsoleerde restorebestemming;
5. Mollie-testprofiel en webhook-URL;
6. SendGrid-afzender, SPF/DKIM-status, template-ID en webhook;
7. de projecteigen schedulercontainer die iedere minuut e-mail/health en dagelijks retentie uitvoert;
8. onafhankelijke `OPERATIONS_HEARTBEAT_URL`, alert-eigenaar en escalatiekanaal.

Gebruik daarna uitsluitend fictieve `example.invalid`-leden. Maak ten minste één account per staffrol en één geblokkeerd staffaccount. Alle drie actieve accounts doorlopen TOTP enrollment; gedeelde accounts zijn verboden.

## Promotie en wijziging

- Configuratie wordt opnieuw opgebouwd uit beheerde omgevingsvariabelen; kopieer geen volledig environmentbestand.
- Een migratie wordt eerst op een schone lokale database en daarna op staging uitgevoerd.
- Een reeds toegepaste migratie wordt nooit gewijzigd; correcties zijn nieuwe forward-fixmigraties.
- Stagingacceptatie promoot alleen de geteste commit-SHA. Rebuild of dependencywijziging vereist heracceptatie.
- Production gebruikt dezelfde artefact-SHA, maar andere secrets en providerconfiguraties.
- Alleen de runtimeflags `MOLLIE_ENABLED` en `EMAIL_ENABLED` en hun gelijknamige beheerde databaseswitches zijn toegestaan. Providerverkeer vereist dat beide lagen aan staan.

## Scheidingscontrole vóór staging

- [ ] Staging-URL gebruikt HTTPS en verschilt van production.
- [ ] Staging Supabase-project en Auth-tenant verschillen van production.
- [ ] Alle stagingsecrets zijn uniek en staan alleen in de secretstore.
- [ ] Mollie gebruikt testmode; een live key is niet aanwezig.
- [ ] SendGrid gebruikt de expliciet goedgekeurde stagingconfiguratie.
- [ ] Providers starten uitgeschakeld.
- [ ] Database bevat alleen fictieve/geanonimiseerde records.
- [ ] Health, scheduler en alerts wijzen naar staging.
- [ ] Back-up- en restoremogelijkheden zijn aantoonbaar beschikbaar.
- [ ] De exacte commit-SHA en canonversie zijn vastgelegd.
