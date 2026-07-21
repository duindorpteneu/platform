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

## Stagingproviderconfiguratie — 2026-07-19

- Mollie staging gebruikt uitsluitend de aanwezige `test_`-key; de read-only profielprobe is groen en de runtimegate staat alleen in staging aan.
- SendGrid staging gebruikt EU-regional `https://api.eu.sendgrid.com`, het bevestigde afzender-/reply-to-adres en webhook-ID `fd290462-a274-4899-82bd-4777cc382bae` op de exacte stagingroute.
- Actions-run `29702162241` wijzigde en herlas de Event Webhook succesvol, zette ECDSA-ondertekening aan, haalde dezelfde P-256 public key terug en leverde die als kortlevend artifact. De key staat nu als publieke GitHub stagingvariable; er is geen secretwaarde uitgelezen.
- Actions-run `29702474022` bevestigde dezelfde webhookconfiguratie opnieuw, maar Mail Send retourneerde veilig gerapporteerd HTTP 401 voordat de runtimeflag werd aangezet. Er is geen mail geaccepteerd en `EMAIL_ENABLED` blijft in staging en production uit.
- De workflow controleert nu vóór Mail Send via `GET /v3/scopes` expliciet of de gebruikte EU-key `mail.send` heeft. Productionwebhook, productiondeploy en productionproviderflags zijn niet aangeraakt of goedgekeurd.

## Medewerker-MFA redirectregressie — 2026-07-20

- De stafflogin en MFA-flow bevestigen na AAL2 voortaan server-side het actieve medewerkersprofiel en bepalen op basis van de canonieke rol het landingspad `/backoffice` of `/uitgifte`.
- Een geldige AAL2-sessie zonder actief `app.staff_profiles`-record blijft op `/staff/mfa` met een concrete activatiemelding; de eerdere stille lus terug naar `/staff/login` is daarmee afgevangen zonder automatisch medewerkersrechten toe te kennen.
- Gerichte routetests dekken fail-closed weigering, private/no-store caching en alle drie rollen. De volledige suite is groen met 41 Vitestbestanden/184 tests, ESLint, TypeScript en de productiebuild.
- De opnieuw gebouwde productie-app doorliep de volledige zelfopruimende browserflow. Die test deactiveert aanvullend het testprofiel na een echte TOTP/AAL2-login en bewijst dat de browser op `/staff/mfa` blijft met de verwachte melding.

## Native Sportlink-ledenexport — 2026-07-20

- De aangeleverde productieachtige CSV is uitsluitend lokaal en geaggregeerd onderzocht; er zijn geen persoonsgegevens gelogd, gekopieerd of gecommit. Structuur: 528 datarijen, 16 kolommen per rij, UTF-8 BOM, geen ongeldige e-mailadressen en geen dubbele relatiecodes.
- De parser herkent nu de native headers `Rel. code`, `Roepnaam` en `Lokale teams`. Formule-injectiecontrole blijft fail-closed op geïmporteerde velden, maar negeert telefoon-/adreskolommen die conform canon niet worden geïmporteerd.
- De echte aangeleverde CSV geeft lokaal exact 528 geldig, 0 ongeldig en 0 dubbel. Previewwaarschuwingen maken 528 ontbrekende seizoenstatussen, 517 lege teams (`Niet ingedeeld`) en 1 roepnaamfallback naar voorletters expliciet vóór commit.
- De importpreview toont geen misleidende groene status meer bij fouten, laat maximaal vijf concrete rijmeldingen zien en bewaart toegepaste fallbacks in de batchmapping.
- `pnpm test` is groen met 41 Vitestbestanden/187 tests; ESLint, TypeScript en `next build` zijn groen. De opnieuw gebouwde productie-app doorliep de volledige zelfopruimende AAL2-browserflow inclusief native Sportlink-preview, fallbackmeldingen en transactionele commit.

## Seizoen-, bulkartikel- en lidstatusbeheer — 2026-07-20

- Forward migrations `20260720130000_season_article_member_management.sql`, `20260720131000_season_management_hardening.sql` en `20260720132000_season_invariant_hardening.sql` zijn vanaf nul toegepast als migrations 40–42, samen met alle eerdere migrations en seed.
- `pnpm test:db` — 16 pgTAP-bestanden en 426 assertions passed. Nieuwe dekking omvat seizoenaanmaak/duplicaat, datum- en bedragconstraints, exact gerespecteerde directe activatie, bulk koppelen/ontkoppelen met herleidbare operationele audit, expliciete AAL1-negatieve tests, beheerder/kledingcommissie/uitgifte-RBAC, actieve-seizoencontext in de lidstatusaudit en blokkade van nieuwe handmatige en Mollie-betalingen voor inactieve én historische seizoensbestellingen.
- `pnpm test` — 41 Vitestbestanden en 190 tests passed; de strikte request-/responsecontracten en datum-, selectie- en redenvalidatie zijn gedekt.
- `pnpm lint`, `pnpm typecheck`, `pnpm security:migrations`, `pnpm security:secrets` en `pnpm build` — passed.
- `pnpm test:db:concurrency` — passed; de bestaande dubbele-uitgiftebescherming blijft intact.
- `pnpm test:dashboard-browser` — passed met echte wachtwoord/TOTP/AAL2-flow. De browser maakt een niet-actief testseizoen aan, koppelt twee artikelen in bulk, inactiveert en reactiveert een lid en verifieert de beveiligde API-responses; alle tijdelijke seizoens-, catalogus-, lid-, Auth- en auditfixtures worden opgeruimd.

## Teamfilter en team-bulkacties — 2026-07-20

- Forward migrations `20260720133000_team_bulk_management.sql`, `20260720134000_team_bulk_snapshot_hardening.sql` en `20260720135000_team_bulk_amount_snapshot.sql` zijn als migrations 43–45 vanaf een schone lokale PostgreSQL 17-database toegepast, inclusief seed.
- `pnpm test:db` — 17 pgTAP-bestanden en 451 assertions passed. De nieuwe tests bewijzen previewtellingen, standaardbedrag voor nieuwe orders, behoud van bestaande exacte bedragen/maten, overslaan van betaalde orders en inactieve leden, per-lid- en exacte variantaudit, rol-/AAL1-afwijzing, NULL-redengrens, ingetrokken oude RPC-rechten en afwijzing van een verouderde snapshot of tussentijds gewijzigd standaardbedrag.
- `pnpm test` — 44 Vitestbestanden en 200 tests passed; request-/responsecontracten, HMAC-tamper/expiry en de gebonden preview/commit-RPC-routering zijn gedekt.
- `pnpm lint`, `pnpm typecheck`, `pnpm security:migrations` en `pnpm build` — passed.
- `pnpm test:dashboard-browser` — opnieuw passed na de snapshot-hardening met een volledige zelfopruimende wachtwoord/TOTP/AAL2-flow. De bestaande server-side teamfilter, ondertekende teamartikelpreview/commit, nieuwe en uitgebreide orders, ondertekende teamstatuspreview/commit, bestaande operationele flows, mobiel/desktop, CSRF en anonieme routebeveiliging zijn gecontroleerd.
- Een onafhankelijke read-only securityreview hercontroleerde previewbinding, phantom-races, NULL-redenen, exacte variantaudit en standaardbedragdrift; alle vijf punten zijn na de forward hardening gesloten.
- Geen productiegegevens, providercredentials of externe productieacties gebruikt.

## Adres-, seizoen- en individuele-matenherstel — 2026-07-20

- Schone lokale reset past 47 forward migrations en seed zonder fout toe; de instellingensingleton wordt nu door migrations zelf gegarandeerd.
- `pnpm test:db` is groen met 19 pgTAP-bestanden en 494 assertions. Nieuwe dekking bewijst gestructureerde verenigings-/afhaaladressen, opslaan zonder actief seizoen, een direct actuele seizoenresponse, maatprofiel-RBAC/AAL2/RLS, stale-writeblokkade, seizoens- en variantconstraints, audit en leidende bestelregels.
- `pnpm test` is groen met 45 Vitestbestanden en 205 tests; instellingen-, maatprofiel- en API-contracten zijn strikt gedekt.
- `pnpm lint`, `pnpm typecheck`, `pnpm security:secrets`, `pnpm security:migrations` en de productiebuild zijn groen; de build bevat de nieuwe beveiligde `/api/members/sizes`-route.
- Concurrency- en echte staff-MFA-integratietests zijn groen. De volledige zelfopruimende AAL2-browserflow slaat een individuele maat op en leest die na reload terug, bewaart verenigings- en afwijkend afhaaladres, ziet een nieuw seizoen direct terug en doorloopt daarna alle bestaande order-, betaling-, QR-, uitgifte-, export- en securityflows.

## Settings/PostgREST staginghotfix — 2026-07-20

- De stagingrelease had migrations `20260720140000` en `20260720141000` aantoonbaar toegepast, maar de settingspagina kon de nieuwe `*_v2`-RPC's niet laden. De bestaande AAL2-layout en uitsluitend voor `beheerder` zichtbare instellingenlink bewezen dat dit geen gewone logout was.
- Forward migration `20260720142000_refresh_postgrest_settings_contract.sql` wijzigt geen settings- of seizoensrijen, publiceert een gegevensvrije service-only contractversie en triggert expliciet `notify pgrst, 'reload schema'`.
- De deploy voert na `supabase db push` en vóór applicatie-activatie maximaal 15 begrensde probes uit. De probe slaagt alleen als PostgREST de actuele contractversie kent en alle drie settings-RPC's voor `authenticated` uitvoerbaar zijn; responsebody's en credentials worden niet gelogd.
- Een schone lokale reset paste alle 48 migrations en seed toe. De echte lokale PostgREST-probe slaagde; `pnpm test:db` gaf 19 bestanden/494 assertions groen en de fulfilment-concurrencytest bleef groen.
- `pnpm test` gaf 46 bestanden/209 tests groen. ESLint, TypeScript, secret- en migrationlint en de productiebuild slaagden.
- De echte staff-MFA-integratie bewees opnieuw AAL2 toegestaan/AAL1 geblokkeerd. De volledige zelfopruimende Playwrightflow bewees settings opslaan, seizoen aanmaken en direct terugzien, artikel-seizoenskoppeling, alle overige kernflows en desktop/mobiele routebeveiliging.

## Mobiele medewerkersnavigatie — 2026-07-21

- De gedeelde `AppShell` rendert op 390×844 een zichtbare menuknop en een modal gelabelde drawer; desktop behoudt de vaste zijbalk.
- De bestaande RBAC-filter bepaalt ook mobiel welke werkruimte- en beheerlinks beschikbaar zijn. De drawer toont de actuele seizoencontext, medewerkersrol en uitlogactie zonder een tweede navigatiecontract te introduceren.
- De Playwrightregressie opent het menu na een echte wachtwoord/TOTP/AAL2-login, controleert Dashboard, Leden, Artikelen, Instellingen en Uitloggen, bewijst body-scroll-lock en focus-trap, sluit met Escape en navigeert via Leden waarbij de drawer sluit.
- `pnpm test`: 46 bestanden/209 tests groen. TypeScript, ESLint en de productiebuild zijn groen; de echte staff-MFA-integratie en volledige zelfopruimende dashboardbrowserflow slagen eveneens.

## Operationele hardening en stagingautomatisering — 2026-07-21

- PR `#14` is gemerged. CI-run `29814090740` slaagde voor applicatiegates, schone Supabase/pgTAP, concurrency, echte MFA en browserreview. Deployrun `29814090899` verifieerde staging voor exact `965233d89eb8dcfb58028ed02b6a637a478103a6`; onafhankelijke `/api/health` gaf `status=ok`, `environment=staging` en dezelfde revision. De productionjob is zonder approval geannuleerd.
- De nieuwe lokale release past 49 forward migrations en seed schoon toe. `pnpm test:db`: 20 bestanden/533 assertions groen, inclusief recovery-RBAC/AAL2, optimistic concurrency, signed-webhookreconciliatie, runledger en health. De fulfilmentconcurrencytest blijft groen.
- `pnpm security:secrets`, `pnpm security:migrations`, ESLint, TypeScript, 56 Vitestbestanden/259 tests, actionlint en ShellCheck zijn groen. De definitieve productiebuild bundelt `/api/email/jobs/[jobId]/recovery`.
- Echte lokale staff-MFA is groen. De volledige zelfopruimende Playwrightflow is opnieuw groen voor AAL2, mobiel menu, Sportlink, seizoenen, teams, maten, orders, exacte kasbetaling, QR, uitgifte, e-mailcentrum, exports, instellingen, audit, CSRF en anonieme routebeveiliging.
- De staging-coreharness gebruikt uitsluitend tijdelijke `example.invalid`-staffaccounts en verwijdert Auth-users/profielen altijd. De Mollieharness is hard gepind op de staginghost, Supabase-ref, testkey, profiel-ID en release-SHA; testbetalingen bevatten geen PII. De restoreworkflow gebruikt een netwerkloze PostgreSQL 17-container op registrydigest en uploadt nooit de dump.
- Extern bewijs voor de nieuwe merge-SHA, Mollie paid/mismatch/replay/refund, live restore-RPO/RTO en onafhankelijke heartbeat wordt pas na de afgeschermde workflowruns toegevoegd. SendGrid Mail Send blijft door de bekende 401 een aparte open providergate.

## Opaque medewerkerssessie na MFA — 2026-07-21

- Na echte Supabase TOTP-verificatie stuurt de browser het kortlevende access-token uitsluitend naar de same-origin sessieroute. Die verifieert met Node/OpenSSL tegen de environmentgebonden publieke ES256-JWK de handtekening, vaste issuer, audience `authenticated`, lifetime, role `authenticated`, `session_id` en exact `aal2`; iedere afwijking faalt vóór databasegebruik.
- Alleen `service_role` kan daarna voor de geverifieerde UUID een app-sessie maken. PostgreSQL vereist een actueel actief staffprofiel en levert rol/seizoen zelf; browserclaims bepalen nooit de autorisatie. De eerdere browser-PostgREST exchangebevoegdheid is met een forward migration ingetrokken.
- De opaque sessie bevat 256 bits entropie, staat alleen als SHA-256-hash in `private`, verloopt na acht uur en wordt via Secure/HttpOnly/SameSite-cookie gevoerd. Iedere apprequest controleert opnieuw vervaldatum, intrekking, actuele rol en actief profiel; application logout trekt de sessie server-side in.
- Schone reset met 52 migrations, 21 pgTAP-bestanden/549 assertions, 60 Vitestbestanden/284 tests, ESLint, TypeScript, productiebuild, securityscans, echte lokale AAL2/AAL1-MFA, concurrency en de volledige zelfopruimende dashboardbrowserflow zijn groen. De browserflow is aanvullend met een lokaal geïnjecteerde JWKS uitgevoerd en bereikte na één herhaling wegens de bekende 5-seconden-SKU-renderfluctuatie alle functionele gates. Exacte staging-SHA en drie-rollenacceptatie worden na merge als externe releasegate uitgevoerd.
- De eerste exacte-SHA stagingrun passeerde de eerdere browser-PostgRESTgrens maar time-outte doordat de appcontainer de publieke JWKS bij een geldig token niet afrondde. De opvolging injecteert de publieke keyset per environment, valideert EC/P-256/ES256 tijdens deploy en gebruikt `createLocalJWKSet` zonder request-time netwerkverkeer.
- Omdat een geldige stagingrequest desondanks geen antwoord gaf, zijn JWT-verificatie en sessie-RPC nu ook op route-niveau onafhankelijk begrensd op vijf en tien seconden. Transportuitval retourneert PII-vrij `STAFF_JWT_UNAVAILABLE` of `STAFF_SESSION_UNAVAILABLE` met 503; ongeldige claims en autorisatieweigering blijven onderscheiden en fail-closed.
- Exacte stagingrun `29853445078` poging 2 maakte de beheerderfixture aantoonbaar gereed en isoleerde daarna een minutenlang open sessieresponse. De eerste bodyreadhypothese leidde tot volledige-bodydekking, maar run `29855800901` bewees dat AbortController alleen de geldige-tokenfase nog niet begrensde. JWT-verificatie en sessie-RPC gebruiken daarom nu onafhankelijke runtimepaden en harde grenzen.
- De stagingfixture schrijft profielen idempotent met upsert en gebruikt bij de externe databaseverbinding maximaal één begrensde retry. Daarmee blijft cleanup veilig herhaalbaar en maskeert een eenmalige hosted-runner/poolerfout de applicatieacceptatie niet.
- De definitieve lokale kandidaat is groen met ESLint, TypeScript, productiebuild, secret- en migrationlint, 60 Vitestbestanden/288 tests, schone reset van 52 migrations, 21 pgTAP-bestanden/549 assertions, fulfilmentconcurrency en echte AAL2/AAL1-MFA. De volledige zelfopruimende dashboardbrowserflow doorliep aanvullend alle kernmodules, instellingen/seizoenen, team- en lidbulkacties en desktop/mobiele routebeveiliging.
- Merge-SHA `da00ff4c8104ecf9ec99e8b5b6b2f4cebdce699d` doorliep CI en immutable stagingdeploy `29855298156` volledig groen. Core-run `29855800901` maakte de beheerderfixture gereed, maar bewees dat ook een alleen op AbortController begrensde volledige-bodyread in de containerruntime nog tot het globale proces-einde kon wachten. De opvolging haalt `jose`/WebCrypto uit het statische geldige-tokenpad ten gunste van Node/OpenSSL ES256 en gebruikt voor de sessie-RPC een onafhankelijke `Promise.race`; de volgende exacte-SHA-run blijft de sluitende gate.
- Gefaseerde core-run `29859837032` bewees dat Supabase TOTP met 200 slaagde en de app binnen 0,33 seconde 403 antwoordde; uitsluitend de Playwright-bodyread hield de oude run open. Met de veilige foutheader rapporteerde run `29861655480` direct `MFA_SYNC_SESSION_REJECTED`: Node/OpenSSL had het AAL2-token dus geaccepteerd, waarna uitsluitend service-role sessie-uitgifte faalde.
- Forward migration `20260721140000_refresh_staff_session_contract.sql` herpubliceert zonder datamutatie alleen het exacte service-rolefunctierecht en triggert PostgREST-schema-reload. De lokale deployprobe bewijst zowel het settingscontract als zichtbaarheid/uitvoerbaarheid van de sessiefunctie via de verwachte fail-closed SQLSTATE; schone reset met 53 migrations en alle 21 bestanden/549 pgTAP-assertions is groen.
- Core-run `29862639560` stopte vóór browserlogin met `STAFF_SESSION_RPC_42501` en bewees dat ook de directe service-rolefixture geen profiel zag. Oorzaak: de geharde psql-container miste `--interactive`, waardoor de via stdin aangeboden upsert nooit in de container aankwam terwijl psql zonder statement status 0 gaf. De harness koppelt stdin nu expliciet; een broncontracttest en de verplichte create/revoke-probe voorkomen regressie.
