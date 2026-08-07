# Omgevingsmatrix

Status: vereiste configuratie tot en met stagingverificatie
Canon: MVP v1.0, hoofdstuk 20, plus goedgekeurd addendum v1.1

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
| `SUPABASE_DB_URL` | Hoog geheim, migration-only | Lokale database op poort 54339 | Directe/pooler migration-URL van uitsluitend het eigen project, TLS niet uitgeschakeld |
| `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | Hoog geheim, server-only | Unieke base64-key van 32 bytes | Uniek per omgeving; nooit build-time hergebruiken |
| `APP_HOST` / `APP_BIND_PORT` | Niet geheim, deploy-only | Niet gebruikt | Exacte host en vaste loopbackpoort 14000/24000 |
| `SUPABASE_JWKS` | Publiek maar omgevingsgebonden | Optioneel; lokale JWKS of tijdelijke lokale endpointfallback | Verplicht; gevalideerde ES256/P-256 keyset van exact het eigen project, zonder runtime-netwerkafhankelijkheid |
| `PARENT_TOKEN_PEPPER` | Hoog geheim, server-only | Uniek, minimaal 32 tekens | Uniek per omgeving; rotatie trekt bestaande oudersessies gecontroleerd in |
| `QR_TOKEN_PEPPER` | Hoog geheim, server-only | Canonieke 32-byte base64url-key | Uniek per omgeving; current key is verplicht |
| `QR_TOKEN_PEPPER_VERSION` | Niet geheim | Geheel getal 1–9999 | Oplopende current keyversie |
| `QR_TOKEN_PREVIOUS_PEPPER` | Hoog geheim, server-only | Leeg buiten rotatie | Alleen tijdelijk en gepaard met previous versie |
| `QR_TOKEN_PREVIOUS_PEPPER_VERSION` | Niet geheim | Leeg buiten rotatie | Anders dan current; pas verwijderen wanneer health beide previous-tellingen nul meldt |
| `CRON_SECRET` | Hoog geheim, server-only | Uniek, minimaal 16 tekens | Uniek per omgeving en uitsluitend scheduler-to-app |
| `DYNAMIC_IMPORT_ENABLED` | Harde runtime-safety switch | `false` | Alleen `true` na versleutelings-, retentie- en DB-featuregate |
| `IMPORT_STAGING_ENCRYPTION_KEY` | Hoog geheim, server-only | Leeg zolang import uit staat; anders uniek | Uniek per omgeving; exact 32 random bytes als 43 tekens base64url zonder padding; deploy blokkeert rotatie/verwijdering met actieve uploads |
| `IMPORT_RAW_RETENTION_HOURS` | Retentieconfiguratie | `24` | Geheel getal 1–72; veilige standaard 24 |
| `OPERATIONS_HEARTBEAT_URL` | Hoog geheim, server-only | Leeg | Unieke externe HTTPS dead-man-switch; verplicht in production en nooit gelogd |
| `MOLLIE_ENABLED` | Harde runtime-safety switch | `false` | Alleen `true` na de bijbehorende gate; database-instelling moet daarnaast aan staan |
| `MOLLIE_API_KEY` | Hoog geheim, server-only | Leeg | Testkey in staging, afzonderlijke live key in production |
| `MOLLIE_PROFILE_ID` | Beschermde providerbinding | Leeg | Protected secret of variable volgens workflow; actueel als secret aanwezig |
| `EMAIL_ENABLED` | Harde runtime-safety switch | `false` | Alleen `true` na de bijbehorende gate; database-instelling moet daarnaast aan staan |
| `SENDGRID_API_KEY` | Hoog geheim, server-only | Leeg | Unieke minimaal bevoegde Mail Send-key |
| `SENDGRID_API_KEY_FINGERPRINT` | Niet-geheime runtimebinding | Leeg | SHA-256 van exact de omgevingsspecifieke Mail Send-key; de applicatie vergelijkt alleen in constant-time en publiceert de waarde niet |
| `SENDGRID_ADMIN_API_KEY` | Hoog geheim, acceptatie-only | Leeg | Alleen staging; afzonderlijke minimaal bevoegde key voor webhookconfiguratie |
| `SENDGRID_API_BASE_URL` | Configuratie | `https://api.sendgrid.com` | Gebruik `https://api.eu.sendgrid.com` uitsluitend voor een EU-regional subuser |
| `SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT` | Niet-geheime accountbinding | Leeg | Alleen staging; SHA-256 van de gecontroleerde `username:user_id`, buiten workflowlogs vastgesteld |
| `SENDGRID_FROM_NAME` | Configuratie | `Kledingcommissie Duindorp SV` | Exact gelijk aan de gepubliceerde afzendernaam |
| `SENDGRID_FROM_EMAIL` | Configuratie | Leeg | Geverifieerd afzenderadres van de omgeving |
| `SENDGRID_REPLY_TO_EMAIL` | Configuratie | Leeg | Operationeel beheerd antwoordadres |
| `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY` | Verificatiesleutel | Leeg | Publieke verificatiesleutel van de omgeving |
| `SENDGRID_WEBHOOK_ID` | Beschermde providerbinding | Leeg | Omgevingsunieke webhook-UUID |
| `SENDGRID_SMOKE_RECIPIENT` | PII, acceptatie-only secret | Leeg | Alleen staging; fictieve, exclusieve testinbox |
| `E2E_MAILBOX_IMAP_HOST` | Acceptatieconfiguratie | Leeg | Alleen staging; TLS-IMAP-host van de testinbox |
| `E2E_MAILBOX_IMAP_PORT` | Acceptatieconfiguratie | `993` | Alleen staging; exact `993` |
| `E2E_MAILBOX_IMAP_MAILBOX` | Acceptatieconfiguratie | `INBOX` | Alleen staging; standaard `INBOX` |
| `E2E_MAILBOX_IMAP_USER` | PII, acceptatie-only secret | Leeg | Alleen staging; nooit in workflowoutput |
| `E2E_MAILBOX_IMAP_PASSWORD` | Hoog geheim, acceptatie-only | Leeg | Alleen staging; unieke app-password/credential |
| `E2E_ADMIN_EMAIL` | PII, acceptatie-only secret | Leeg | Alleen staging; bestaande geïsoleerde beheerder voor de echte AAL2-testmailflow |
| `E2E_ADMIN_PASSWORD` | Hoog geheim, acceptatie-only | Leeg | Alleen staging; uniek wachtwoord van de geïsoleerde E2E-beheerder |
| `E2E_ADMIN_TOTP_SECRET` | Hoog geheim, acceptatie-only | Leeg | Alleen staging; base32-secret van exact één geverifieerde TOTP-factor, nooit gelogd |
| `STAGING_CLEANUP_BACKUP_PASSPHRASE` | Hoog geheim, cleanup-only | Leeg | Alleen staging; minimaal 32 tekens en los van appkeys |
| `PRODUCTION_BACKUP_PASSPHRASE` | Hoog geheim, promotion-only | Leeg | Alleen production; minimaal 32 tekens, versleutelt het herstelpunt dat vóór iedere migratie duurzaam wordt geüpload |
| `RELEASE_ARTIFACT_DIGEST` | Niet geheim, deployment-generated | Leeg | Exacte SHA-256 van het getransporteerde image-archief; komt uit het gesigneerde manifest en wordt nooit handmatig ingesteld |

Geen enkele geheime variabele krijgt een `NEXT_PUBLIC_`-prefix. Secrets staan niet in GitHub-workflowtekst, screenshots, tickets, logs of testbewijs. De repository bevat alleen lege voorbeelden.

De deploymentnaamgeving wordt bewust vertaald naar het runtimecontract:
`NEXT_PUBLIC_APP_URL` wordt `APP_BASE_URL`,
`NEXT_PUBLIC_SUPABASE_ANON_KEY` wordt
`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` en
`SUPABASE_SERVICE_ROLE_KEY` wordt `SUPABASE_SECRET_KEY`. De workflow
controleert beide namen zonder waarden te tonen.

## Actuele GitHub-aanwezigheid (2026-08-07, alleen namen gelezen)

De environments zijn opnieuw rechtstreeks via de GitHub-API geïnventariseerd;
secretwaarden zijn niet gelezen. Staging bevat de Supabase-, server-action-,
parent-, QR-, cron-, import-, Mollie-, Mail Send- en recoverable-cleanupsecrets.
Project-ref, lokale JWKS, QR-versie, 24-uurs importretentie, webhook-public-key,
webhook-ID en de goedgekeurde afzendernaam/-adressen staan als variables. De
testinboxpoort is `993` en de mailboxnaam `INBOX`. Providers en dynamische
import blijven standaard uit.

Nog ontbrekend in staging:

- `OPERATIONS_HEARTBEAT_URL` met een echte alert-eigenaar en bewezen gemiste
  ping plus herstel;
- `SENDGRID_ADMIN_API_KEY`, `SENDGRID_API_KEY_FINGERPRINT` en
  `SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT` voor een dedicated stagingaccount of
  subuser en een accountgebonden webhook-/Mail Send-acceptatie;
- `E2E_MAILBOX_IMAP_HOST`, `E2E_MAILBOX_IMAP_USER`,
  `E2E_MAILBOX_IMAP_PASSWORD`, `E2E_ADMIN_EMAIL`, `E2E_ADMIN_PASSWORD` en
  `E2E_ADMIN_TOTP_SECRET` voor machine-verifieerbare AAL2-testmail en
  inboxbezorging.

Production bevat nu ook unieke, zonder output gegenereerde
`QR_TOKEN_PEPPER`, `IMPORT_STAGING_ENCRYPTION_KEY` en
`PRODUCTION_BACKUP_PASSPHRASE`; `QR_TOKEN_PEPPER_VERSION=1`, retentie `24` en
de drie runtimefeatures staan veilig op `false`. De vaste afzendernaam en
adressen zijn aanwezig. Nog ontbrekend zijn
`OPERATIONS_HEARTBEAT_URL`, `SENDGRID_API_KEY_FINGERPRINT` en
`SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY`. Production blijft daardoor en door de
host-/acceptatiegates NO-GO.

Deployhost, SSH-user/-port/-key, known-hosts, externe containerregistry en
Tailscale zijn niet van toepassing: deployments draaien lokaal op afzonderlijke
self-hosted runners en transporteren het gesigneerde image als Actions-artifact.
Dit is geen toestemming om runner- of hostconfiguratie buiten de repository te
wijzigen.

`main` is op 2026-08-07 beschermd met strikte vereiste checks
`Application quality gates` en `Supabase migration and pgTAP gates`, één
goedkeuring, last-push-approval, opgeloste gesprekken, lineaire historie,
adminhandhaving en blokkade van force-push/delete. Staging en production
accepteren uitsluitend `main`. Production heeft één verplichte reviewer; de
environment is succesvol met `prevent_self_review=true` bijgewerkt. De
artifactketen gebruikt daarnaast een plan-onafhankelijke keyless
Sigstore/Cosign-bundel.

## Staging-aanmaak

Voor de eerste stagingdeploy legt de releasebeheerder buiten Git vast:

1. eigenaar en EU-regio van app en Supabase;
2. staginghostnaam, projectreferentie en secretstore-locatie;
3. technische beheerder, incidentcontact en privacycontact;
4. back-upmogelijkheid en gekozen geïsoleerde restorebestemming;
5. Mollie-testprofiel en webhook-URL;
6. SendGrid-afzender, SPF/DKIM-status, template-ID en webhook;
7. de projecteigen schedulercontainer die iedere minuut e-mail/health en uiterlijk iedere vijf minuten retentie uitvoert;
8. onafhankelijke `OPERATIONS_HEARTBEAT_URL`, alert-eigenaar en escalatiekanaal.

Gebruik daarna uitsluitend fictieve `example.invalid`-leden. Maak ten minste één account per staffrol en één geblokkeerd staffaccount. Alle drie actieve accounts doorlopen TOTP enrollment; gedeelde accounts zijn verboden.

## Promotie en wijziging

- Configuratie wordt opnieuw opgebouwd uit beheerde omgevingsvariabelen; kopieer geen volledig environmentbestand.
- Een migratie wordt eerst op een schone lokale database en daarna op staging uitgevoerd.
- Een reeds toegepaste migratie wordt nooit gewijzigd; correcties zijn nieuwe forward-fixmigraties.
- Stagingacceptatie promoot alleen de geteste commit-SHA. Rebuild of dependencywijziging vereist heracceptatie.
- Production gebruikt dezelfde artefact-SHA, maar andere secrets en providerconfiguraties.
- Alleen de runtimeflags `MOLLIE_ENABLED`, `EMAIL_ENABLED` en `DYNAMIC_IMPORT_ENABLED` en hun gelijknamige beheerde databaseswitches zijn toegestaan. Providerverkeer en dynamische import vereisen dat beide lagen aan staan.
- Na migraties maar vóór appactivatie bewijst de service-only importstaging-gate dat de runtimekey alle niet-verlopen uploads kan ontsleutelen; de fingerprint wordt nooit in release-output getoond.

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
