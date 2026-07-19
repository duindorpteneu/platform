# Test evidence

## Stagingprovider- en staffonboardingfixes — 2026-07-19

- `pnpm test` — 39 Vitest-bestanden en 177 tests passed; omvat expliciete Mollie `public`/`app`-schemaroutering, SendGrid job-UUID-correlatie, ontbrekende `sg_message_id`, global/EU API-hostselectie en strikte invite-fragmentvalidatie.
- `pnpm lint` en `pnpm typecheck` — passed.
- `pnpm db:reset` — passed; alle 39 vooruitrollende migrations en seed zijn vanaf nul toegepast.
- `pnpm test:db` — 15 pgTAP-bestanden en 391 assertions passed; SendGrid-eventcorrelatie gebruikt een andere `sg_message_id` dan de Mail Send-header en blijft bij replay exact één keer verwerkt.
- `pnpm build` — passed; `/staff/set-password` is in het productieartefact gebundeld.
- `git diff --check` — passed.
- Geen providersecretwaarde gelezen of gelogd; geen productieactie uitgevoerd. Live Mollie- en SendGrid-smokes wachten op de stagingconfiguratie en expliciete testdata.

Record commands, results and relevant screenshots/notes per phase.
## Phase 0 / foundation — 2026-07-18

- `./node_modules/.bin/tsc --noEmit` — passed.
- `./node_modules/.bin/eslint .` — passed.
- `./node_modules/.bin/next build` — passed; routes generated: `/`, `/backoffice`, `/login`, `/mijn-tenue`, `/uitgifte`.
- Visual direction implemented from the supplied Duindorp SV showcase and logo assets; browser screenshot review remains part of the next UI gate.
## Phase 1 / staff data foundation — 2026-07-18

- Migration added: `supabase/migrations/20260718000100_foundation.sql`.
- Local service ports reserved in `supabase/config.toml` after a read-only port preflight.
- Server-only Supabase client and role guard added; live Auth/RLS verification is pending local Supabase configuration.
- `pnpm test` — passed (2 role-permission tests).
- `pnpm typecheck` — passed.
- `pnpm lint` — passed.
- `pnpm typecheck`, `pnpm lint` and `pnpm build` — passed after middleware typing fix.
- Sportlink preview tests: 3 passed; total unit tests: 5 passed.
- `pnpm build` — passed; dynamic route `/api/imports/preview` generated.
- `pnpm typecheck` — passed sequentially after build (parallel race avoided).
- Backoffice routes `/backoffice/leden`, `/backoffice/artikelen` and dynamic operational modules compile and render in production build.
- `pnpm test` — passed (5 tests).
- `pnpm lint`, `pnpm build` and sequential `pnpm typecheck` — passed after adding `/api/imports/commit`.
- Supabase migration execution remains pending because the Supabase CLI/local database is not installed in this workspace.
- Handmatige betaalboundarytests: 2 passed; totaal unit tests: 7 passed.
- `pnpm lint`, `pnpm build` en sequentiële `pnpm typecheck` — passed na toevoegen van `/api/payments/manual`.
- Parent auth tests: 2 passed; totaal unit tests: 9 passed.
- `pnpm lint`, `pnpm build` and sequential `pnpm typecheck` — passed for parent auth routes.
- Private schema access was reviewed and routed through RPC wrappers; plaintext OTP is not persisted.
- Parent route correction validated: `/login`, `/login/code`, `/staff/login` and `/mijn-tenue` generated in build.
- `pnpm test` (9 passed), `pnpm lint`, `pnpm build` and sequential `pnpm typecheck` — passed after Suspense fix.
- Parent member-link test: 1 passed; totaal unit tests: 10 passed.
- `pnpm lint`, `pnpm build` and sequential `pnpm typecheck` — passed for parent member access endpoints.
- SQL migration `20260718000700_parent_member_access.sql` is pending execution against a clean local Supabase database.
- Ouderportaal UI `/mijn-tenue` buildt met loading, unauthorized, error, empty en success states.
- `pnpm test` (10 passed), `pnpm lint`, `pnpm build` and sequential `pnpm typecheck` — passed.

## Phase 5 / voorraad, QR en deeluitgifte — 2026-07-18

- Migrations toegevoegd: `20260718000750_cancelled_order_line_status.sql`, `20260718000800_inventory_qr_fulfilment.sql` en `20260718000900_manual_payment_qr.sql`.
- Statische review uitgevoerd op role checks, RLS-default-deny, voorraadlocking, QR-hercontrole, betaalhercontrole, unieke actieve fulfilment per orderregel en audit zonder plaintext token.
- Request-boundarytests toegevoegd voor leveringsontvangst, onmogelijke datum, dubbele variant, dubbele reserveringsregel, QR-payload en dubbele uitgifteselectie.
- `pnpm test` — 8 testbestanden en 19 tests passed.
- `pnpm lint` — passed.
- `pnpm typecheck` — passed.
- `pnpm build` — passed; `/api/stock/receipts`, `/api/stock/reservations`, `/api/fulfilment/lookup`, `/api/fulfilment/commit` en `/uitgifte` zijn succesvol gebundeld.
- Camera wordt uitsluitend gestart na gebruikersactie en tracks worden bij sluiten/unmount gestopt; browsers zonder `BarcodeDetector` krijgen een veilige invoerfallback.
- Playwright renderde `/uitgifte` lokaal op 1440×1000 en 390×844; beide viewports hadden geen horizontale overflow (`scrollWidth === clientWidth`) en de primaire scan-/controleacties waren respectievelijk 160 en 44 pixels hoog. Screenshots zijn gegenereerd; beeldinspectie in Codex bleef door een lokale sandbox-viewerfout niet beschikbaar.
- De projectlokale Supabase-stack draait geïsoleerd en gezond op API 54329, PostgreSQL 54339, Studio 54349, Mailpit 54359 en Analytics 54369; de bestaande Fieldgrid-container bleef ongewijzigd op 55432.
- Parent QR migration `20260718001000_parent_qr_version.sql` geeft uitsluitend de actieve tokenversie terug aan de service-role RPC; de bearerwaarde wordt server-side afgeleid en als QR-data-URL uitsluitend binnen de geautoriseerde ouderresponse geleverd.
- `qrcode@1.5.4` en de bijbehorende typen zijn projectlokaal gepind; geen externe QR-renderdienst of tracking-URL wordt gebruikt.
- `/qr` buildt als neutrale publieke pagina zonder lid-, order- of betaalgegevens.
- Na ouder-QR-integratie: `pnpm test` (19 passed), `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed.
- `pnpm db:reset` — passed op PostgreSQL 17.6; alle 13 migrations en `supabase/seed.sql` zijn vanaf nul toegepast.
- Foundation-volgorde hersteld nadat PostgreSQL aantoonde dat SQL-functies vóór `app.staff_profiles` werden geparseerd.
- RLS-hardening migrations `20260718121500_restrict_issuance_rls.sql` en `20260718122500_harden_app_privileges.sql` toegepast.
- `pnpm test:db` — 2 pgTAP-bestanden, 18 assertions passed; omvat negatieve uitgifte-RLS, rolgrenzen, voorraadoverschrijding, deeluitgifte, dezelfde QR en dubbele-uitgifteblokkade.
- `pnpm test:db:concurrency` — passed; twee gelijktijdige PostgreSQL-sessies resulteerden in exact één fulfilment en `ORDER_LINE_NOT_READY` voor de tweede balie.
- Na databasehardening: `pnpm test` (19 passed), `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed.
- Migration `20260718124000_stock_overview.sql` vanaf nul toegepast als veertiende migration; `pnpm db:reset` inclusief seed — passed.
- Voorraad-RPC roltests toegevoegd: `uitgifte` wordt met `42501` geweigerd en `kledingcommissie` krijgt toegang.
- `pnpm test:db` — 2 pgTAP-bestanden en 20 assertions passed na toevoeging van het voorraadoverzicht.
- Leveringenwerkruimte aangesloten op `/api/stock/overview`, `/api/stock/receipts` en `/api/stock/reservations` met server-side rolcontrole en transactionele mutaties.
- Na de leveringenwerkruimte: `pnpm test` — 9 bestanden en 21 tests passed; `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed.
- Playwright renderde `/backoffice/leveringen` op 1440×1000 en 390×844 zonder horizontale overflow; de primaire acties waren 40 en 44 pixels hoog en de ongeautoriseerde foutstatus bleef neutraal.

## Staff Auth/MFA hardening — 2026-07-18

- Migrations `20260718130000_staff_aal2.sql` en `20260718131000_staff_role_fail_closed.sql` toegevoegd en als migration 15 en 16 vanaf een schone database toegepast.
- Een SQL NULL-guardfout in bestaande SECURITY DEFINER-rolchecks werd door de AAL1-negatietest gevonden; `app.staff_role()` sluit nu centraal met `42501` bij ontbrekende AAL2, account of actief profiel.
- `pnpm test:db` — 2 pgTAP-bestanden en 21 assertions passed; actief profiel op AAL1 wordt aantoonbaar geweigerd.
- `pnpm test:db:concurrency` — passed na AAL2-hardening.
- `pnpm test:staff-mfa` — passed; echte lokale Supabase Auth-flow promoveert van AAL1 naar AAL2, AAL2-RPC slaagt en AAL1-RPC retourneert `42501`; fixture wordt verwijderd.
- Playwright voltooide wachtwoordlogin, eerste TOTP-QR-enrollment, verificatie, backoffice met echte naam/rol en lokale logout terug naar `/staff/login`.
- Ongeautoriseerde `/backoffice` retourneert 307 naar `/staff/login` met `private, no-store`; login en MFA hebben op 1440×1000 en 390×844 geen horizontale overflow.
- Staff-layout is `force-dynamic`; de productiebuild markeert alle backoffice- en uitgifteroutes als server-rendered on demand.
- Definitieve gates: `pnpm test` — 9 bestanden en 22 tests passed; `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed.

## Fixturevrij operationeel dashboard — 2026-07-18

- Migration `20260718140000_backoffice_dashboard.sql` vanaf nul toegepast als migration 17; personeelsshell en dashboardaggregatie sluiten fail-closed op actief profiel, AAL2 en rol.
- Dashboard-RPC geeft uitsluitend actief seizoen, tellingen, maximaal vijf recente bestellingen zonder e-mailadres en maximaal vijf auditgebeurtenissen zonder metadata terug.
- `pnpm db:reset` — passed; alle 17 migrations en `supabase/seed.sql` zijn schoon toegepast.
- `pnpm test:db` — 3 pgTAP-bestanden en 38 assertions passed; omvat AAL1-weigering, weigering van `uitgifte`, minimale shelltoegang voor `uitgifte`, exacte KPI's, PII-uitsluiting, QR-lookupfilter en leeg-seizoen.
- `pnpm test` — 10 bestanden en 26 tests passed; de strikte shell- en dashboardcontracten accepteren geldige/lege responses en weigeren extra PII, extra shellvelden en negatieve tellingen.
- `pnpm test:db:concurrency` — passed; één fulfilment slaagt en de concurrerende tweede balie wordt geblokkeerd.
- `pnpm test:staff-mfa` — passed; echte lokale AAL2-sessie toegestaan en AAL1 met `42501` geweigerd.
- `pnpm test:dashboard-browser` — passed als zelfstandig commando; start en stopt de productie-app, maakt een tijdelijk beheerderaccount met TOTP en volledig fictieve operationele data aan, valideert KPI's en verwijdert alle fixtures.
- Browsercontrole: 1440×1000 en 390×844, geen horizontale body-overflow, actuele seizoen-/profieldata zichtbaar, voormalige fixtures `486`, `Danny`, `Zaterdag 22 juli` en `laatste sync` afwezig.
- Screenshots: `after-dashboard-desktop.png` en `after-dashboard-mobile.png` in het lokale sprintartefact; testdata en MFA-factor zijn na vastlegging verwijderd.
- Definitieve applicatiegates: `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed; `/backoffice` blijft dynamisch server-rendered.

## Operationeel ledenoverzicht en Sportlink-commit — 2026-07-18

- Migrations `20260718150000_member_overview.sql` en `20260718151000_sportlink_summary.sql` zijn als migration 18 en 19 schoon toegepast.
- `pnpm db:reset` — passed; alle 19 migrations en `supabase/seed.sql` zijn vanaf nul toegepast op de geïsoleerde PostgreSQL 17-stack.
- `pnpm test:db` — 5 pgTAP-bestanden en 75 assertions passed; omvat AAL1- en `uitgifte`-weigering, PII-minimale lijst, alle filters, paginering, detailgegevens, ouderkoppelingen, orderregels, QR-status, historie en Sportlink change summary/commit.
- `pnpm test` — 11 bestanden en 31 tests passed; strikte query-, lijst- en detailcontracten weigeren ongeldige selecties, identifiers en extra PII/QR-tokens. De Sportlink databaseadapter is afzonderlijk getest.
- `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed; `/backoffice/leden` en beide importroutes zijn dynamisch gebundeld.
- `pnpm test:db:concurrency` — passed; één fulfilment slaagt en de concurrerende tweede balie wordt geblokkeerd.
- `pnpm test:staff-mfa` — passed; AAL2 wordt toegestaan en AAL1 retourneert `42501`.
- `pnpm test:dashboard-browser` — passed na een schone database-reset; controleert wachtwoord + TOTP, dashboard, live ledenlijst, serverfilters, expliciet detail, responsiviteit, CSV-upload, change preview, transactionele commit, terugzoekbaarheid en anonieme redirect.
- Browserfixtures, MFA-account, importbatch en geïmporteerd testlid worden in `finally` verwijderd; de productie-app wordt door het script gestopt.
- Screenshots: `after-members-desktop.png` op 1440×1000 en `after-member-detail-mobile.png` op 390×844; mobiel heeft geen horizontale body-overflow.

## Operationeel catalogus-, bestel-, QR- en correctiebeheer — 2026-07-18

- Migration `20260718160000_catalog_orders_corrections.sql` is als migration 20 schoon toegepast op PostgreSQL 17.6, inclusief seed en expliciete seizoenskoppelingen voor standaardartikelen.
- `pnpm db:reset` — passed; alle 20 migrations en `supabase/seed.sql` zijn vanaf nul toegepast.
- `pnpm test:db` — 6 pgTAP-bestanden en 127 assertions passed. Gedekt zijn AAL1-/rolweigering, catalogus- en orderinvarianten, exacte betaling, paid immutability, service-only secrets, oude/nieuwe/ingetrokken QR, beide correctiedoelen, dubbelcorrectie, reserveringen, audit en PII-/hashuitsluiting.
- `pnpm test` — 14 bestanden en 41 tests passed; catalogus/ordercontracten, eurocentconversie, QR-/correctierequests en bestaande domeingrenzen zijn groen.
- `pnpm test:db:concurrency` — passed; exact één gelijktijdige fulfilment en blokkade van de tweede balie.
- `pnpm test:staff-mfa` — passed; echte AAL2-sessie toegestaan en AAL1 met `42501` geweigerd.
- `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed; expliciete dynamische routes `/backoffice/artikelen`, `/backoffice/bestellingen`, `/backoffice/uitgifte`, `/api/qr/rotate` en `/api/fulfilment/reverse` zijn gebundeld.
- `pnpm test:dashboard-browser` — passed als zelfopruimende productieflow: wachtwoord + TOTP, catalogusartikel en variant aanmaken, open order wijzigen, betaalde order alleen-lezen, QR roteren/intrekken/heractiveren, foutieve uitgifte corrigeren en anonieme redirect.
- De browserfixture geeft lokale testprocessen de Supabase- en QR-testconfiguratie uitsluitend in-memory door; sleutels worden niet gelogd, opgeslagen of gecommit.
- Screenshots in `operations-sprint`: `after-catalog-desktop.png`, `after-orders-desktop.png`, `after-corrections-desktop.png` en `after-member-security-mobile.png`, naast de dashboard- en ledenregressies. De app en alle fictieve data/MFA-factoren zijn in `finally` verwijderd.
- `git diff --check` — passed.

## Providerintegraties en operationele communicatie — 2026-07-18

- Tien vooruitrolbare providermigrations (`20260718170000` tot en met `20260718179000`) zijn vanaf nul toegepast; totaal 30 migrations op lokale PostgreSQL 17.6.
- `pnpm db:reset` — passed inclusief seed.
- `pnpm test:db` — 11 pgTAP-bestanden, 238 assertions passed; 111 nieuwe assertions dekken provider-RLS, exact bedrag/valuta/metadata, drievoudige replay, mismatch/manual review, duplicate paid, refund/QR-intrekking, queue locking, retrylimiet, bulkreplay, immutable snapshots, OTP-immutability en parent-effective-status.
- `pnpm test` — 26 testbestanden en 92 tests passed; omvat Mollie request/response, classic webhook, metadatafouten, eventkeys, SendGrid tracking-off/reply-to, raw-body signatures, shortcodes, previewtokens en PII-minimale contracts.
- `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed; alle provider-, e-mail-, betaal- en publieke retourroutes zijn succesvol productiegebundeld.
- `pnpm test:dashboard-browser` — passed met echte lokale wachtwoord/TOTP/AAL2-flow en zelfopruimende fixtures; controleert bestaand dashboard/leden/operations plus e-mailcentrum, bulkselectie, betaalregister, neutrale Mollie-retour en anonieme routebeveiliging.
- Responsive browsercontrole: 1440×1000 voor e-mailcentrum en betaalregister, 390×844 voor Mollie-retour; geen horizontale body-overflow.
- Screenshots: `artifacts/provider-sprint/after-email-center-desktop.png`, `after-payments-desktop.png` en `after-payment-return-mobile.png`; lokale artefacten zijn van git uitgesloten.
- Live SendGrid SPF/DKIM/delivery en Mollie test-mode checkout/webhook blijven staginggates; er zijn geen live credentials of productieacties gebruikt.

## Releasehardening en lokale staginghandoff — 2026-07-18

- `pnpm install --frozen-lockfile` — passed.
- `pnpm audit --prod --audit-level moderate` — passed: geen bekende kwetsbaarheden.
- `pnpm security:secrets` — passed: geen high-confidence credentials of gevolgde runtime-environmentbestanden.
- `pnpm security:migrations` — passed: 36 uitsluitend vooruitrollende migrations gecontroleerd.
- `pnpm db:reset` — passed op de geïsoleerde PostgreSQL 17-stack; alle 36 migrations en seed vanaf nul toegepast.
- `pnpm test:db` — 15 pgTAP-bestanden, 383 assertions passed. Dit omvat negatieve RLS, exports, retentie/health, instellingen/audit, zoek-rate-limit en alle eerdere domeininvarianten.
- `pnpm test:db:concurrency` — passed: exact één fulfilment, tweede gelijktijdige balie geblokkeerd.
- `pnpm test:staff-mfa` — passed: AAL2 toegestaan, AAL1 aantoonbaar geweigerd.
- `pnpm test` — 35 Vitest-bestanden, 158 tests passed.
- `pnpm lint` en `pnpm typecheck` — passed.
- `pnpm build` — passed; Next.js rapporteert de middleware expliciet in het productieartefact en bundelt settings, audit, health, jobs en export.
- `pnpm test:e2e` — tweemaal achtereen passed na timinghardening. De flow bewijst wachtwoord + TOTP/AAL2, dashboard, leden/Sportlink, catalogus, bestellingen, exacte kasbetaling, QR, uitgiftecorrecties, e-mailcentrum, betaalregister, Mollie-retour, instellingen, audit, CSV/XLSX, securityheaders, correlation-id, negatief CSRF-pad, mobiel/desktop en anonieme redirect.
- De E2E-fixture verwijdert aantoonbaar Auth-user, MFA-factor, staffprofiel, leden, orders, betalingen, QR, fulfilments, voorraad, e-mailjobs, batches, events, import en catalogusdata; een directe telling na de run was nul.
- Screenshots in het lokale staginghandoffartefact: dashboard desktop/mobiel, leden desktop, lid/security mobiel, catalogus, bestellingen, correcties, e-mailcentrum, betaalregister, Mollie-retour mobiel, instellingen, audit en exports.
- Geen live providercredentials, productiegegevens, productiewebhooks of productieacties gebruikt.
- Externe open gates: publieke HTTPS-stagingdeploy, Mollie testmode-roundtrip/replay, SendGrid-afzender/inbox/eventwebhook, Supabase-staffuitnodiging, scheduler/alerts en geïsoleerde restore-drill.

## Self-hosted VPS-deploybasis — 2026-07-18

- `actionlint 1.7.12` is via de officiële releasechecksum geverifieerd en accepteert `ci.yml`, `deploy-staging.yml` en `deploy-production.yml` met de twee vastgelegde custom runnerlabels.
- Beide workflowbestanden en `.github/actionlint.yaml` zijn daarnaast als YAML geparseerd.
- Geldige fictieve staging- en productionconfiguraties slagen door `configure-runtime.mjs`; een Mollie live-key in staging wordt aantoonbaar geweigerd.
- `bash -n` en `node --check` slagen voor alle nieuwe deployscripts; `git diff --check`, migration lint en secret scan zijn groen.
- `pnpm lint`, sequentiële `pnpm typecheck`, 35 Vitest-bestanden/158 tests en `pnpm build` zijn groen met `output: standalone`.
- Het door het deployscript gebruikte release-layout (`server.js`, `.next/static`, `public`) is in een tijdelijke map gestart en serveert succesvol via een vrije loopbackpoort.
- Remote Supabase-migratie, systemd-herstart, Caddy-HTTPS en publieke health blijven bewust ongeverifieerd totdat de nieuwe VPS, DNS, twee Supabase-projecten en GitHub-configuratiewaarden beschikbaar zijn.

## Bewerkbaar ouder-OTP-template — 2026-07-18

- Forward migration `20260718186000_editable_parent_otp_template.sql` maakt `verification_code` via dezelfde AAL2/RBAC-, versie- en audit-RPC bewerkbaar en voegt uitsluitend `{{verificatiecode}}`, `{{clubnaam}}` en `{{contact_email}}` aan de OTP-allowlist toe.
- Een OTP-template zonder `{{verificatiecode}}` wordt zowel applicatief als in PostgreSQL fail-closed geweigerd.
- Het service-only template-RPC levert alleen de actuele bron, versie en noodzakelijke clubcontext; `authenticated` heeft geen execute-recht.
- De echte zescijferige code wordt pas in geheugen gerenderd voor directe SendGrid Mail Send en staat niet in de duurzame jobqueue, templatebron of auditmetadata. Het aparte SendGrid Dynamic Template-ID-configuratiecontract is verwijderd.
- Schone reset: 37 migrations en seed toegepast. `pnpm test:db`: 15 bestanden en 390 assertions groen; concurrency groen.
- `pnpm lint`, `pnpm typecheck`, 36 Vitest-bestanden/162 tests en standalone `pnpm build` zijn groen.
- `pnpm test:e2e` is groen en bewijst in de echte AAL2-backoffice dat onderwerp/body actief bewerkbaar zijn, de opslagactie beschikbaar is en de fictieve preview `{{verificatiecode}}` als `123456` rendert zonder de template op te slaan.

## Definitieve VPS-deploymentfinalisatie — 2026-07-19

- GitHub environmentvariables en secret-namen via `gh` geaudit; Supabaseprojectrefs zijn verschillend en URL-consistent. De staginghosttypefout is gecorrigeerd zonder secrets te lezen of overschrijven.
- `bash -n`, ShellCheck en `node --check` slagen voor het centrale deployscript en alle helpers.
- Composeconfig voor staging en production rendert één appservice met `host_ip: 127.0.0.1`, respectievelijk poort 14000 en 24000, zonder `build:`.
- Definitieve applicatiegates: secret- en migrationlint, ESLint, TypeScript, 37 Vitestbestanden/166 tests en `next build` groen. Health dekt JSON/200, 503 bij ontbrekende releaseconfig en redactie bij geworpen fouten; de OTP-challenge dekt versleuteling, expiry en tamperafwijzing.
- Actionlint 1.7.7 is na officiële checksumcontrole groen; ShellCheck, `bash -n`, Node-syntax en `git diff --check` zijn groen.
- De uiteindelijke Dockerfile bouwt onder Rootless Docker. Een geharde tijdelijke container retourneert zonder kritieke runtimeconfig redacted 503 op health en eindigt voor `/`, `/admin` en `/uitgifte` correct op HTTP 200 (met toegestane staffloginredirects).
- Die oorspronkelijke handoff had nog geen echte VPS-deploy; inmiddels zijn de environmentsecret-namen en productionapproval extern ingericht en is de eerste stagingrun als herstelbewijs hieronder vastgelegd.

## Eerste stagingdeploy-herstel — 2026-07-19

- Actions-run `29693692256` bewees dat preflight, alle repositorygates, de immutable imagebuild en artifactupload slaagden. Staging stopte vóór migratie en `compose up` doordat Docker op de Rootless containerd-store de OCI-manifestdigest als `.Id` rapporteerde, terwijl het buildmanifest de configdigest bevatte.
- Release-manifest v2 verifieert afzonderlijk OCI-manifestdigest, configdigest en SHA-256 van het exacte gecomprimeerde transportartefact. De bijbehorende blobs, releasetag en SHA-label worden vóór activatie gecontroleerd.
- De basisimage is op registrydigest gepind; `docker save` gebruikt een metadata-neutrale gzip en hetzelfde artifact blijft de enige staging-naar-production-eenheid.
- Alle checkouts gebruiken `persist-credentials: false`; alleen de twee noodzakelijke private `origin/main`-fetches krijgen tijdelijk `${{ github.token }}` via een HTTP-extraheader.
- Runtimepreflight koppelt staging en production hard aan hun eigen Supabase-ref en valideert JWT-ref, directe databasehost/pooler-user en het verbod op `sslmode=disable`.
- Nieuwe Vitest-contracttests bewijzen beide canonieke environments, negatieve production-in-stagingconfiguratie, runtime-browserinjectie en vergelijking van alle drie releasedigests. Totaal: 38 testbestanden en 171 tests groen; lint, TypeScript, build, actionlint, ShellCheck, Bash-/Node-syntax, migration-/secretscan en beide Compose-renders zijn groen.

## Hosted Data API-schemaherstel — 2026-07-19

- Actions-run `29696764081` paste alle 37 bestaande migrations succesvol toe, verifieerde het releaseartefact en startte `duindorpteneu-staging-app-1`; de eerdere 502 was daarmee opgelost.
- De lokale containerhealth bleef 503. Een PII- en secretvrije REST-probe op het publieke Supabase-endpoint gaf exact HTTP 406 / `PGRST106`: het custom schema `app` stond niet in de hosted PostgREST-allowlist.
- Forward migration `20260719100000_expose_app_data_api.sql` houdt de hosted allowlist gelijk aan `supabase/config.toml`, herlaadt PostgREST en laat `private` bewust buiten de Data API.
- pgTAP controleert de effectieve `authenticator`-rolconfiguratie; de deployment-contracttest bewaakt dat lokale config en hosted migration dezelfde schema's noemen.
- Lokale verificatie is groen: schone reset met 38 migrations, 15 pgTAP-bestanden/391 assertions, 38 Vitestbestanden/172 tests, secret- en migrationlint, ESLint, TypeScript, productiebuild, concurrency, echte AAL2/AAL1-MFA, actionlint, ShellCheck en de volledige zelfopruimende browserflow.
- Een echte lokale REST-aanroep met `Content-Profile: app` retourneerde HTTP 200 en exact de vier PII-vrije healthvelden; daarmee is de oorspronkelijke `PGRST106`-route rechtstreeks afgedekt.
- Deployrun `29697586669` paste migration `20260719100000` succesvol toe, herstartte `duindorpteneu-staging-app-1` en bewees via een publieke, secretvrije schema-probe dat `PGRST106` weg is. Health bleef 503 en `/` gaf 500 doordat disabled SendGrid-contactwaarden als lege strings door de runtimeconfiguratie werden geschreven en vervolgens als ongeldige aanwezige e-mailadressen faalden.
- De opvolgende runtimefix laat lege optionele providervelden weg uit `.env.runtime` en normaliseert expliciete lege waarden defensief naar afwezig; unit-, deploymentcontract- en volledige browsertests starten de productie-app expliciet met lege disabled-providerwaarden, terwijl de bestaande provider-on contracten fail-closed blijven.
- Lokale hotfixgates zijn groen: ESLint, TypeScript, productiebuild, 38 Vitestbestanden/174 tests, secret- en migrationlint, actionlint, ShellCheck en de volledige zelfopruimende AAL2-browserflow met expliciet lege disabled-providerwaarden.

## Publiek gezonde stagingrelease — 2026-07-19

- PR `#5` is na groene applicatie- en Supabase/pgTAP/MFA/browserchecks gemerged. Deployrun `29698271201` bouwde één immutable artifact en verifieerde staging volledig voor revision `dee16f14220ccb6bedb16fcfb449f627ef222866`.
- De remote database was bij dry-run en apply actueel; `duindorpteneu-staging-app-1` is opnieuw aangemaakt en gestart. De deployrunner controleerde zowel `http://127.0.0.1:14000` als de publieke HTTPS-host, inclusief health, root, admin en uitgifte.
- Publieke onafhankelijke verificatie: `/api/health` HTTP 200 met uitsluitend `status=ok`, `service=duindorpteneu`, `environment=staging` en de verwachte revision; `/` HTTP 200; `/admin` en `/uitgifte` HTTP 307 naar dezelfde-host `/staff/login`, daarna HTTP 200.
- Geverifieerd manifest v2: image `duindorpteneu-app:dee16f14220ccb6bedb16fcfb449f627ef222866`, OCI-digest `sha256:a795e370971a2cd3d63809652c77ea43b2bc62bb8433c6c2b9c56c2be446665d`, configdigest `sha256:5893ba0229b54de44449cc662eb110e1d227d2af7ee2d3e9315965be4a2e8802` en transportdigest `sha256:7e7b4c5047196f03f203f78a48ebe004c55168271b000400f60e776c92e4b8a3`.
- De productionjob is niet uitgevoerd en staat achter de required-reviewer-gate voor `TIXOCEO`; er is geen approval verleend.
