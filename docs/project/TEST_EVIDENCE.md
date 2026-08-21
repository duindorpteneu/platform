# Test evidence

## PR 116 tijdelijke SMTP-fallback — 2026-08-19

- `pnpm install --frozen-lockfile --ignore-scripts` — passed na lockfileherstel voor `@types/node@22.19.15`, `@types/nodemailer@7.0.1` en de naar `9.0.5` gepatchte `nodemailer`.
- `pnpm security:dependencies` — passed; Nodemailer high advisories zijn opgelost door de gepatchte 9.x-versie.
- `.github/workflows/deploy.yml` gebruikt tijdelijk `EMAIL_PROVIDER=smtp` als stagingdefault zolang SendGrid niet werkt; productionpromotie blijft op SendGrid tenzij expliciet anders geconfigureerd.
- `pnpm vitest run src/server/email/providers/smtp.test.ts src/app/api/internal/jobs/email/route.test.ts scripts/deploy/deployment-contract.test.ts` — passed; 56 gerichte tests groen.
- `node scripts/check-migrations.mjs` — passed.
- `pnpm db:reset` — passed vanaf een schone lokale PostgreSQL 17-database.
- `pnpm test:db` — passed; 58 pgTAP-bestanden en 1879 assertions groen.
- `pnpm test:db:email-attempt-concurrency`, `pnpm test:db:mail-campaign-concurrency`, `pnpm test:db:mail-projection-concurrency` en `pnpm test:db:mail-supersession-concurrency` — passed.
- `pnpm lint:workflows`, `pnpm lint`, `pnpm typecheck`, `pnpm test` en `pnpm build` — passed; 215 Vitest-bestanden en 1317 tests groen.
- `pnpm test:db:staging-cleanup` — passed na schone reset; cleanupcontract bevat na samenvoegen met PR 115 nu 108 expliciete operationele tabellen inclusief `private.email_bulk_rate_limit` en pakketassignments.

## PR 115 pakketmaten en Mollie-fixtureherstel — 2026-08-19

- `pnpm install --frozen-lockfile --ignore-scripts` — passed.
- `pnpm vitest run src/app/api/parent/packages/select/route.test.ts src/app/api/parent/members/route.test.ts src/components/member/member-dashboard.test.ts` — passed; de verwachte negatieve `parent.workspace_schema_invalid`-log blijft beperkt tot de schematest.
- `node scripts/check-migrations.mjs` — passed.
- `pnpm lint`, `pnpm typecheck`, `pnpm test` en `pnpm build` — passed; 213 Vitest-bestanden en 1304 tests groen.
- `pnpm db:reset` — passed vanaf een schone lokale PostgreSQL 17-database.
- `pnpm test:db` — passed; 58 pgTAP-bestanden en 1879 assertions groen.
- `pnpm test:db:mollie-fixture` — passed; cleanup houdt rekening met pakketassignments vóór orderverwijdering.
- Gerichte DB-concurrencyharnassen voor fulfilment, package, payment, refund, inventory, delivery-notification, mail-projection, mail-supersession en email-attempt zijn lokaal groen.
- `pnpm test:db:staging-cleanup` — passed; cleanupcontract bevat na samenvoegen met PR 116 nu 108 expliciete operationele tabellen inclusief pakketassignments, `private.email_bulk_rate_limit` en behoudt staff/Auth/config.

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
- Core-run `29863954993` bewees vervolgens dat de profiel-upsert, service-role sessieaanmaak en intrekking, Supabase MFA (200), same-origin app-sessie (200) en landing als beheerder slagen. Alleen de eerste `/api/settings`-request gaf daarna 403. De opvolging herpubliceert en probet daarom ook `get_staff_app_session` en `revoke_staff_app_session`, en controleert vóór settings expliciet of de opaque cookie opnieuw tot een appcontext resolveert.
- Core-run `29865330238` bewees aanvullend dat dezelfde opaque cookie op een volgende request opnieuw 200 geeft. De resterende settings-403 kwam van een ongeldige `GET` op de POST-only mutatieroute en was dus een harnessfout. De definitieve check opent voor beheerder de echte settingspagina en controleert voor kledingcommissie dat de beheerlink ontbreekt.

## Exacte stagingacceptatie, settingsherstel en restore — 2026-07-21

- Forward migration `20260721221000_settings_active_boolean_contract.sql` corrigeert de SQL-drie-waardelogica in de settingsworkspace: wanneer `active_season_id` null is, retourneert ieder bestaand seizoen nu expliciet `active: false` in plaats van `null`. De regressietest bootst exact “seizoenen aanwezig, geen actief seizoen” na.
- Een schone lokale reset paste 55 migrations en seed toe. `pnpm test:db` is groen met 21 pgTAP-bestanden/550 assertions; `pnpm test` met 60 bestanden/293 tests, ESLint, TypeScript, productiebuild en de volledige lokale AAL2-browserflow zijn groen.
- PR `#47` doorliep op definitieve branch-SHA CI-run `29873098282`: applicatiegates, schone Supabase, alle migrations/pgTAP/RLS, fulfilmentconcurrency, echte MFA en volledige browserreview slaagden. De catalogus-E2E leest een toegevoegde variant na herladen uit de database terug en is daarmee niet meer afhankelijk van een 5-seconden client-renderwindow.
- Deployrun `29873523343` bouwde en verifieerde het immutable image en paste migration 55 toe op staging voor exact `76bfe4ef4a5e4348668c37647e8b72e3299a98c9`; preflight, migratie, containerstart, publieke health/revision en route-/RPC-probes zijn groen.
- Core-run `29873991736` is groen op dezelfde SHA. Echte Supabase TOTP gaf 200, same-origin sessieaanmaak en hergebruik gaven 200, het settings-RPC én Zod-responsecontract gaven 200, de beheerder zag de echte instellingenpagina, kledingcommissie zag geen beheerlink en alle drie rollen slaagden voor RBAC en het mobiele menu. Alle tijdelijke `example.invalid`-fixtures zijn verwijderd.
- Restore-run `29874124335` is groen op dezelfde SHA. Een actuele logical backup is binnen de vastgelegde RPO/RTO naar een run-unieke netwerkloze, digest-gepinde PostgreSQL 17-container hersteld; schema-, constraint- en geaggregeerde controles slaagden. Alleen het geredigeerde 1004-byte evidence-artifact is 14 dagen bewaard; dump, containers, volumes en tijdelijke bestanden zijn altijd verwijderd.
- Production is niet uitgevoerd of goedgekeurd. De resterende externe gates zijn `MOLLIE_PROFILE_ID`, unieke `OPERATIONS_HEARTBEAT_URL`-secrets, een SendGrid-key met werkende `mail.send`-scope/inboxbewijs, de gekozen uitgifteapparaatmatrix en aantoonbaar gescheiden VPS-user/rootless-runnerboundaries naast Castivo.

## Mollie testmode-acceptatie — 2026-07-22

- De stagingconfiguratie accepteert de aanwezige pooler-URL voor exact Supabase-project `dxbdjtbyghsovlrdcwcr`; fixture-DML loopt bewust via service-role-only hosted Data API-RPC's. Een tijdelijk testseizoen wordt alleen gemaakt als staging geen actief open seizoen heeft en wordt altijd samen met alle fictieve `example.invalid`-data opgeruimd.
- De applicatie leest operationele providerflags via een service-role-only RPC. Daardoor werken zowel Mollie als SendGrid fail-closed zonder directe tabelprivileges voor de runtime.
- `pnpm test` is groen met 60 bestanden/304 tests. ESLint, TypeScript, productiebuild, 59 forward-only migrations, 22 pgTAP-bestanden/571 databaseasserties, fulfilmentconcurrency, echte staff-MFA en de volledige Playwrightreview zijn groen in CI-run `29918249899`.
- Deployrun `29918250069` bouwde één immutable image, paste de migrations toe en verifieerde interne en publieke health/routes voor exact SHA `7e50810e77bf1d65c3c95af2930e35ee0a0cf329`.
- Mollie-acceptatierun `29918711338` is groen op exact dezelfde SHA. De flow maakte via het publieke oudercontract twee testbetalingen van € 1,00, voltooide de hosted iDEAL-testcheckout, verwerkte paid via de publieke webhook, bewees drie gelijktijdige replays idempotent en hield gemanipuleerde metadata unpaid met handmatige review.
- De hosted testflow maakte vervolgens een echte volledige refundresource aan. Mollie retourneerde die binnen de run correct als `pending`: nog annuleerbaar en nog zonder klassieke webhook. De lokale betaling en QR bleven daarom terecht betaald/actief. De runtime haalt payment en refundlijst parallel op; zodra Mollie `processing` of `refunded` rapporteert, verwerkt dezelfde webhookgrens dit fail-closed als refund en trekt zij de QR in. Dit terminale pad is aanvullend door unit-, service- en databasetests gedekt.
- De acceptance-finally én de afzonderlijke always-run cleanup hebben dezelfde fixture idempotent verwijderd. Er zijn geen persoonsgegevens, secretwaarden of productiebetalingen gelogd; production is niet uitgevoerd of gewijzigd.

## Runtime-image security recovery — 2026-08-11

- PR `#49` was wel gemerged als `965727294307326ec0a2953f2ab4968fb3eac07b`; deployrun `31434321788` stopte daarna vóór stagingactivatie op de bestaande `Reject high or critical runtime vulnerabilities`-gate.
- De falende final-image scan rapporteerde voor Debian 12.15 17 HIGH/5 CRITICAL en voor de meegeleverde globale npm-installatie 7 HIGH/1 CRITICAL. De applicatie-afhankelijkheden in het standalone image hadden zelf geen HIGH/CRITICAL-bevinding.
- Met dezelfde lokale Trivy 0.70.0-database zijn kandidaatbasissen vergeleken: `node:22-trixie-slim` 25 HIGH/5 CRITICAL, distroless Node 22 Debian 12 5 HIGH/1 CRITICAL en de digest-gepinde distroless Node 22 Debian 13-basis 0 HIGH/0 CRITICAL. Er is geen scanuitzondering of severityverlaging toegevoegd.
- Het volledige gebouwde kandidaatimage `sha256:cb841526aadd1792b8aa6ef94eb62399916e4e200b253e556227e2b76e3ba28e` is daarna opnieuw gescand: 0 HIGH/0 CRITICAL. Het draait als numeric uid 65532 op Node `v22.23.2`, bevat geen shell/npm/npx/corepack/yarn en heeft werkende CA/DNS/TLS en `Europe/Amsterdam`-tzdata.
- Een echte 1×1-PNG-transformatie vond eerst dat Next standalone de optionele pnpm-libvips-symlink niet volgde. De gepinde Sharp 0.35.0/libvips 1.3.0-runtime wordt daarom expliciet vanuit de builder gekopieerd; de herhaalde Sharp-smoke is groen.
- De appcontainer is met read-only rootfs, tmpfs, alle capabilities verwijderd en `no-new-privileges` gestart: `/staff/login` gaf 200, `/api/health` gaf zonder runtimeconfig bewust 503, en de procesuid was 65532. De scheduler-entrypoint bleef met minimale stagingtestconfig actief en beide absolute Compose-healthchecks configureren geldig.
- Lokale gates op de herstelbranch: actionlint groen; ESLint groen; TypeScript groen; 191 Vitestbestanden/1.101 tests groen; productiebuild groen; dependency-audit zonder bekende kwetsbaarheden; secretscan groen; migrationlint groen voor 136 forward-only migrations; Composeconfig groen. Hosted CI en de scan van het exacte immutable releaseartifact volgen na de herstel-PR.

## PostgREST-contractdiagnose en herstel — 2026-08-11

- GitHub deployrun `31441758899`, poging 2, job `93774419426` bewees runnerboundary, runtimepreflight, 136 bestaande migrations, remote dry-run en volledige forward push groen. De checker faalde pas daarna, vóór runtimewrite/containeractivatie, met `REQUEST_FAILED`; production is niet benaderd of gewijzigd.
- Statische signaturevergelijking en de nieuwe HTTP-contractintegratietest bewijzen de fout: `confirm_inventory_delivery_notification_proposal_v1` verwacht `p_excluded_item_ids`, maar de deploychecker stuurde `p_selected_item_ids`. De daaropvolgende veilige foutcode was 83 tekens en werd door de oude limiet van 64 tekens onterecht vervangen.
- `scripts/deploy/check-postgrest-rpcs.test.mjs` doorloopt de versie-, staffsessie-, password-recovery-, QR-, health-, ouder-, staffbeheer- en verboden-fixtureprobes met de exacte profielen en requestbody. `scripts/deploy/postgrest-diagnostics.test.mjs` bewijst timeout/DNS/TLS/connectclassificatie, nested/AggregateError-prioriteit, onbekende fallback en onderdrukking van niet-vertrouwde fout-/responsecodes.
- Gerichte gate: 3 testbestanden, 44 tests groen, inclusief de fail-closed blokkade voor de schema-incompatibele stagingrelease `a846c059bce3d7e794504acca57a4771dfdb536d`. De checker is daarnaast tegen de echte lokale PostgREST-stack geslaagd zonder secret- of PII-output.
- De volledige lokale applicatiegate is groen: ESLint, TypeScript, 193 Vitestbestanden/1.115 tests, productiebuild, actionlint, secretscan, dependency-audit zonder bekende kwetsbaarheden en migrationlint met 137 forward-only migrations.
- Een schone lokale reset heeft alle 137 migraties gereplayd. De volledige pgTAP-suite is groen met 53 bestanden/1.749 asserties; de staff-recovery-nullprobe is afzonderlijk groen met 20 asserties en bewijst dat staffsessies, exchanges, QR-scangrants en auditlogs bytegelijk blijven. De productieachtige expand-upgrade vanaf `20260802170000` heeft alle 77 Phase-B-migraties toegepast met ongewijzigde legacy-hashes en groene reconciliatie. De leveringnotificatieconcurrency bewijst één bevestiging, één eventset en een idempotente retry. Hosted CI en stagingdeploy volgen op de kandidaatcommit.

## Staging readiness en edge-bodyprobe — 2026-08-11

- PR `#52` is gemerged als `35d3b1ab0ebf79b1ccf58d7c2ec5d6a04cc6c264`. CI-run `31495033428`, poging 2, is op exact die SHA volledig groen: applicationgates, 137 schone migrations, 53 pgTAP-bestanden/1.749 asserties, concurrency, MFA/password-recovery, ouderportaal en volledige Playwrightreview.
- Deployrun `31495033431`, poging 3, hergebruikte het eerder gebouwde en ondertekende immutable artifact. Na de staging-only, geaudite reconciliatie `app_settings.email_enabled=false` slaagden migrations, PostgREST, importkey, runtime-secretcontrole en interne/publieke kandidaatapp-health. De schedulercontainer startte; de finale schedulerhealthcheck werd door de eerdere edgefout niet bereikt. Daarna gaf alleen de eerste edgeprobe `EDGE_BODY_LIMIT_FAILED:standard-api:403`; fail-safe stopte kandidaat en scheduler en startte de schema-incompatibele oude image niet. Production bleef onaangeraakt.
- Officiële Caddy 2.10.2-source en een echte lokale containerreproductie bewijzen de oorzaak: `request_body max_size` wrapt lazy met `http.MaxBytesReader`; een vroeg upstreamantwoord kan vóór max+1 worden teruggegeven. De catalogusroute valideerde Origin vóór body-read, zodat de oude anonieme probe met actieve cap terecht `403` kon zien.
- Het nieuwe contract gebruikt decimale grenzen `128000`, `384000`, `2000000` en `12000000`. De no-op branch is HMAC-SHA256/constant-time, route-/host-/omgeving-/release-/byte-/tijd-/noncegebonden, streamt zonder bodybuffer en raakt geen productstate. Exact max retourneert `204`+marker; max+1 retourneert zonder Caddy eveneens niet-`413`, zodat alleen Caddy de vereiste markerloze `413` kan leveren.
- Gerichte lokale verificatie: 69 probe-/route-/redactie-/deploycontracttests groen, TypeScript groen en `pnpm test:edge-proxy` groen tegen digest-gepinde Caddy `2.10.2`. De integratietest gebruikt het echte Caddy-snippet, bewijst alle vier grens/max+1-paren, reproduceert vroege `403` en detecteert een opzettelijk verhoogde standaardcap. `pnpm test:edge-runtime` bewijst met de gebouwde standalone Next-productieruntime dat de interne runtime-URL plus publieke proxyheaders geldig zijn en dat 12.000.000 én 12.000.001 chunked bytes onverkort de side-effectvrije branch bereiken.
- Volledige lokale applicatiegate op de herstelbranch: dependency-audit zonder bekende kwetsbaarheden, secretscan, lint van alle 137 forward-only migrations, ESLint, TypeScript, actionlint, 194 Vitestbestanden/1.137 tests, 25 logprivacytests, productiebuild en de afzonderlijke echte Caddy- en Next-runtimetests groen. Database-/browsergates worden door CI opnieuw op de exacte kandidaat-SHA uitgevoerd.

## Immutable runtime-bodygateway — 2026-08-11

- Main-SHA `d55818313216d7c14d74c46421936a0e81277e01` doorliep CI-run `31515140971` volledig groen. Deployrun `31515141010` bouwde, scande, ondertekende en startte hetzelfde artifact, maar de publieke max+1-probe bereikte bij `standard-api` de applicatie met gemarkeerd `204`. De deploy stopte kandidaat en scheduler fail-closed; de schema-incompatibele vorige app werd niet gestart en production is niet benaderd.
- De forward-fix verscheept de pre-parsergrens in hetzelfde distroless image: gatewaypoort 3000, Next uitsluitend op `127.0.0.1:3001`, vier routegebonden decimale caps en geïsoleerde pools met samen maximaal `37632000` bufferbytes. Ambigue CL+TE, dubbele Content-Length, niet-canonieke Transfer-Encoding, hop-by-hopheaders, fragmentatie, time-out, capaciteit en groepsisolatie zijn negatief getest.
- Gerichte contractmatrix: 45/45 tests groen. De echte standalone productieruntime accepteert voor alle vier HMAC-routegroepen exact de grens met `204` en marker, en weigert grens+1 vóór Next met markerloos `413`. Startup-race, ontbrekende upstream, bezette poort en graceful SIGTERM zijn fail-closed; een onafhankelijke read-only review vond geen resterende blocker.
- Volledige lokale applicatiegate: 195 Vitestbestanden/1.145 tests, ESLint, TypeScript, productiebuild, echte Caddytest en echte gateway-/Next-runtimetest groen. Dependency-audit meldt geen bekende kwetsbaarheden; secretscan, actionlint en lint van alle 137 forward-only migrations zijn groen.
- Het actuele Dockerfile bouwt het shell-loze Debian 13 distroless image. Een read-only/no-capabilities/no-new-privileges-smoke draaide gateway en Next als uid 65532, `/api/health` bereikte de app, een oversize Content-Length gaf pre-parser `413` en SIGTERM eindigde met exitcode 0. Trivy 0.70.0 met actuele database rapporteerde 0 HIGH/0 CRITICAL voor OS en runtimepackages. Hosted immutable-image- en exact-SHA-stagingbewijs blijven verplicht na merge.

## Result-bound stagingattest — 2026-08-11

- Main-CI `31525432811` is volledig groen op `4788233867a8f55cb4615c5d4d804811be5986a1`. Deployrun `31525432825` bewees daarna runnerisolatie, ondertekende checksums/SBOM, 0 HIGH/CRITICAL, alle remote migrations, PostgREST-contracten, runtimehealth, schedulerstart en de vier publieke exact-max/max+1-bodylimieten groen.
- De enige mislukte stap was de aansluitende attestcreatie. Het al geüploade deployresultaat had een geldige GitHub artifact-ID en een kale 64-hex `artifact-digest`; het script wees die semantisch geldige SHA-256 af vóór attestupload. Cleanup is daardoor niet gestart.
- De gerichte regressiematrix telt 80/80 groene tests over stagingattest, stagingdeployverificatie en promotiebewijs. De nieuwe test bewijst dat kale upload-artifactuitvoer canoniek als `sha256:<hex>` wordt opgeslagen en tegen zowel kale als geprefixte verwachtingen wordt geverifieerd; korte of anders gevormde digests blijven geweigerd.
- De volledige lokale herstelgate is groen: ESLint, TypeScript, production build, 195 Vitestbestanden/1.146 tests, actionlint, secretscan, dependency-audit zonder bekende kwetsbaarheden en lint van alle 137 forward-only migrations.

## Cleanup self-hosted Node-runtime — 2026-08-11

- Exacte main-CI `31532871940` en stagingdeploy `31532871841` zijn groen op `27a4d275c436092b731530837142aaef9e2dd917`; het nieuwe result-bound deployattest is aangemaakt en geüpload.
- Cleanup-dry-run `31535542508` passeerde het secrets-vrije trusted-main-/artifact-/attestbewijs en de stagingrunnerboundary. De eerstvolgende stap stopte vóór databaseconnectie met exit `127` op `node scripts/staging/validate-target.mjs`; apply werd door de modusconditie overgeslagen en er is geen data gemuteerd.
- De regressietest leest de echte workflow, splitst dry-run en apply en eist in beide jobs runnerboundary → commit-gepinde setup-node → Node 22 → targetvalidator. Hosted exact-SHA CI en een nieuwe staging-dry-run blijven verplicht.
- De lokale herstelgate is groen: actionlint, ESLint, TypeScript, production build, 195 Vitestbestanden/1.147 tests, secretscan, dependency-audit zonder bekende kwetsbaarheden en lint van alle 137 forward-only migrations. Een onafhankelijke read-only review vond geen blocker.

## Cleanup expliciete database-TLS — 2026-08-12

- Main-SHA `d28e6304000cf8dff81286dd49799605566427c8` is volledig groen in CI-run `31538103762` en immutable stagingdeploy `31538103757`. De deploy bevat het exacte result-bound attest waarop cleanup-dry-run `31540435039` succesvol preflightte.
- In de stagingjob waren checkout, runnerboundary en Node 22 groen. `validate-target.mjs` stopte daarna vóór databaseconnectie met `Cleanup vereist een expliciete TLS-databasemodus`; de geaggregeerde query en applyjob zijn niet gestart en stagingdata is niet gemuteerd.
- De nieuwe unitmatrix bewijst: ontbrekende `sslmode` wordt `require` zonder de toegestane `connect_timeout` te verliezen; `require`, `verify-ca` en `verify-full` blijven intact; TLS-downgrades, dubbele/ongekende parameters, letterlijke of percent-encoded multi-hosts en niet-PostgreSQL-URL's worden geweigerd. Negatieve tests dekken expliciet libpq-overrides voor host, Unix-socket, hostaddr, poort, database, user/password, servicefile en options in normalisator én targetvalidator. De workflowtest eist in zowel dry-run als apply setup-node → gemaskeerde TLS-normalisatie → strikte targetvalidatie en exact twee korte raw-secretgrenzen.
- Gerichte lokale verificatie: actionlint groen, ESLint groen, TypeScript groen en 3 Vitestbestanden/58 tests groen. Na de readinessregressietest is de volledige suite groen met 197 bestanden/1.179 tests; productiebuild, secretscan, 137-migratielint en dependency-audit zonder bekende kwetsbaarheden zijn groen. Een onafhankelijke security-herreview vond geen resterende blocker.
- PR-CI-run `31541363200` bewees de volledige applicationgate en alle database-, RLS-, migratie-, concurrency-, capaciteit-, MFA-, password-recovery- en ouderportaalstappen groen. De afsluitende browserreview vond vervolgens een bestaande readinessflaky: na een geslaagde `db reset` werd lokale Supabase Auth niet binnen de vaste 30 seconden API-ready. Het harnas gebruikt nu dezelfde echte admin-Auth-probe tot een begrensde deadline van 120 seconden en gaat zonder extra wachttijd verder zodra Auth gezond is; timeout blijft fail-closed. Een statische contracttest bewaakt probe, deadline en het verwijderen van de oude 30-secondenpogingengrens.

## Cleanup exact herstelrolcontract — 2026-08-12

- PR58-hoofdbewijs: main-SHA `c5793058fbf26243f1aaed1eef735a75cd47790f`, volledige CI-run `31546059030` en immutable stagingdeploy `31546059043` zijn groen op exact dezelfde commit.
- Dry-run `31547931988` is groen met contractversie, nieuwste migration `20260811130000`, exact 100 cleanup-/28 preserve-tabellen, 2.126 rijen in 12 niet-lege cleanup-tabellen, 2 actieve beheerders en nul actieve importleases, scangrants, databaseproviderflags, inflight e-mailjobs en open providerbetalingen. Het bewijs bevat uitsluitend tellingen en tabelnamen, geen PII.
- Applyrun `31548081925` stopte veilig in de preparefase. Migration-, schema-, ACL- en RLS-restorevergelijking waren groen; de broninventaris werd daarna door de oude harde `roles.length === 12` geweigerd omdat hosted staging elf kernrollen heeft en `supabase_functions_admin` ontbreekt. Backupartifactupload en applyfase zijn niet bereikt; de database is niet gemuteerd en stagingapp/scheduler zijn door de trap gezond herstart.
- De regressiematrix accepteert exacte restores met elf én twaalf toegestane rollen en weigert een ontbrekende kernrol, onbekende rol en duplicaat. Het bronobject wordt volledig gevalideerd vóór de PII-vrije literal `true|false`; beide shellentrypoints geven die waarde expliciet door en SQL faalt als zij ontbreekt. Statische tests borgen alle drie conditionele create-/alter-/grantblokken en behouden de eindvalidatie na `pg_restore`.
- Gerichte lokale verificatie: `bash -n` voor cleanup en restore-drill, `node --check`, ESLint, TypeScript en 2 Vitestbestanden/16 tests groen. In een tijdelijke container van exact `public.ecr.aws/supabase/postgres:17.6.1.143` op de gepinde digest zijn de psql-takken werkelijk uitgevoerd: `false` liet de Functions-rol afwezig, `true` maakte exact één; de container is daarna verwijderd.
- De volledige lokale gate is groen: 197 Vitestbestanden/1.184 tests, ESLint, TypeScript, production build, actionlint, secretscan, lint van 137 forward-only migrations en dependency-audit zonder bekende kwetsbaarheden. Hosted exact-SHA-gates volgen op de kandidaatcommit. Production is niet benaderd of gewijzigd.

## Cleanup exact postgres-rollenlidmaatschap — 2026-08-12

- Mainbewijs vóór de gevonden drift: SHA `62452722ed4c6468674d66b733fba5c42913794c`, CI `31555228135`, deploy `31555228167` en cleanup-dry-run `31556865165` groen.
- Apply `31556954276` bewees eerst exacte migrations, schema, ACL en RLS, maar de volledige bron/restore-inventaris blokkeerde op uitsluitend `roles[changed=1:postgres:memberships]`. Er was geen backupartifactupload, geen cleanup-apply en geen datamutatie; app en scheduler herstelden gezond.
- Gerichte regressiematrix: bronbooleancombinaties voor Functions-rol en realtime-membership, onbekende/dubbele/ontbrekende/verkeerd toegewezen memberships, Functions-rol/membershipkoppeling en concrete source=false/restored=true-drift. De cleanupcontracttest vereist één conditionele realtime-grant en dezelfde afleiding in cleanup en restore-drill.
- Echte gepinde PostgreSQL 17-image, `--network none`: realtime-membership `false` blijft afwezig, `true` wordt toegekend en een ontbrekende psql-variabele stopt met exitcode 3. Tijdelijke container en volume zijn verwijderd.
- Volledige lokale gate: dependency-audit zonder bekende kwetsbaarheden, secretscan, 137 forward-only migrations, actionlint, ESLint, TypeScript, 197 Vitestbestanden/1.194 tests en production build groen.
- Hosted PR-CI `31557615605`: alle application-, DB/RLS-, migratie-, concurrency-, cleanup-, capaciteit-, MFA-, recovery- en oudergates groen; alleen de finale browserreview stopte nadat de Mail-v2-preview aantoonbaar HTTP 2xx gaf maar de vaste iframe-wachttermijn verliep. De readinessregressietest vereist nu response-completion, exacte renderpayloadvorm, zichtbare previewstatus en expliciete desktopmodus zonder herhaalde previewaanvraag.
- Een aanvullende directe lokale E2E-poging draaide onder de niet-repositorycanonieke Node 24 en stopte al bij de stafflogin→MFA-navigatie, vóór de gewijzigde Mail-v2-controle. Zij geldt niet als bewijs; de verplichte exacte Node 22-browserjob in hosted CI moet de wijziging nog integraal bewijzen.
- Hosted PR-CI `31558961377` op `969c9e118d2ea0892644e24cebb7075a72bb3790`: application quality volledig groen; legacy-upgrade, clean replay, DB/RLS, Mollie-SQL, alle concurrencytests, cleanupcontract, capaciteit/p95, staff-MFA, password recovery en oudertoegang groen. De finale review stopte uitsluitend op de toegevoegde klik naar de reeds standaard actieve desktopmodus. De gecorrigeerde assertie muteert geen previewmodus en wacht binnen de zichtbare previewsectie rechtstreeks op de iframe; exacte-headbewijs is opnieuw vereist.
- Hosted PR-CI `31560035083` op `fb9b8507de358502f22f639e570fa62db4d7873d`: dezelfde volledige voorliggende matrix groen; de finale review zag de fictieve previewstatus maar vond de titelgebonden iframe niet binnen tien seconden. Het aangescherpte contract activeert desktop uitsluitend binnen de concrete previewmodusgroep en bewijst daarna `aria-pressed`, de veilige frametitel en exacte gelijkheid van `srcdoc` aan de gevalideerde response-HTML. Exact-headbewijs blijft vereist.
- Hosted PR-CI `31561107406` op `93bb9d2feb8175b725c057a26ee77e1ad071f2f9`: application quality en opnieuw alle DB/RLS-, migratie-, concurrency-, cleanup-, capaciteit-, MFA-, recovery- en oudergates groen. De finale review ontving en valideerde de volledige Mail-v2-previewresponse, maar de previewstatus werd daarna binnen de UI weer gewist.
- De oorzaak is in de gepinde TipTap 3.29.2-runtime en de applicatiecode bewezen: `Editor.setEditable` emit standaard een `update`, terwijl Mail-v2 iedere async actie via `disabled={Boolean(busy)}` editable/read-only schakelt en `onUpdate` in de parent `markDirty()` plus `setPreview(null)` uitvoert. De eventloze `setEditable(!disabled, false)` behoudt echte editorupdates maar laat een busy-wissel geen inhoud muteren. Dezelfde onafhankelijke review vond dat templatecontent één render na de nieuwe revisiesleutel wordt gecommit; content-sync bewaakt daarom ook de contentprop en muteert TipTap uitsluitend eventloos als de editor-JSON werkelijk afwijkt. jsdom-tests voeren de echte TipTap-methoden uit en bewijzen ook wisselen tussen twee verschillende template-inhouden zonder valse `onChange`. Hosted exact-headbewijs volgt.
- Volledige lokale kandidaatgate na beide editorcorrecties: dependency-audit zonder bekende kwetsbaarheden, secretscan, 137 forward-only migrations, actionlint, ESLint, TypeScript, 198 Vitestbestanden/1.197 tests en production build groen. Er is geen browsertestretry, skip of acceptatieversoepeling toegevoegd.

## Mollie Phase-B oudergrantfixture — 2026-08-14

- Stagingrun `31758878351` is groen voor de volledige Phase-B candidate matrix en deployed surfaces. Mollie-run `31760358236` bereikte daarna de geïsoleerde SQL-prepare, maar stopte op `MOLLIE_ACCEPTANCE_PARENT_OTP_CREATE_INVALID`; er is geen providerbetaling gestart en de fixturecleanup draaide.
- De regressie gebruikt geen legacy `link_parent_member`. Prepare maakt exact één deterministisch `example.invalid`-account en twee actieve, seizoensgebonden grants met een run-unieke synthetische actor. De hosted service-RPC's bewijzen daarna OTP, sessie en uitsluitend de twee verwachte fixtureleden.
- De SQL-integratietest bewijst idempotente prepare, nul globale configuratiemutatie, nul legacylinks, exact twee grants in het actieve seizoen, collisionblokkade vóór mutatie bij een afwijkende actor en nul account-/grantresten na cleanup.
- Lokale uitslag: 24/24 gerichte tests; 1.216/1.216 volledige Vitesttests; SQL-fixture groen; ESLint, TypeScript, secretscan, 138-migratielint en production build groen.

## Mollie begrensde refundconsistentie — 2026-08-14

- Live observatie: stagingacceptatie `31768226017` passeerde betaalcreatie, hosted testbetaling, oudertoegang, betaald-zonder-QR, transactioneel teruggedraaide voorraad/allocatie/QR-readiness, drie concurrente webhookreplays en metadata-mismatch. De Molliepagina bevestigde de volledige refund; de API bleef binnen zestig seconden `pending`, waarna cleanup de fictieve fixture verwijderde en de databaseprovidergate weer gesloten is.
- Gerichte regressie: `pnpm vitest run scripts/providers/mollie-staging-acceptance.test.ts` is groen met 26/26 tests. De nieuwe gevallen bewijzen terminal succes na meerdere niet-terminale polls en expliciete timeout op blijvend `pending`; gedeeltelijke of niet-terminale refunds blijven ongeldig.
- Hosted eindbewijs vereist opnieuw exacte main-SHA, immutable stagingdigest en een groene `staging-mollie-acceptance.yml` binnen de vaste twintigminutengrens. Production is niet benaderd.
- Volledige lokale kandidaatgate: `pnpm lint`, `pnpm typecheck`, `pnpm lint:workflows`, `pnpm security:secrets`, `pnpm security:migrations`, `pnpm security:dependencies`, `pnpm test` en `pnpm build` zijn groen. Resultaat: 138 migrations, 198 testbestanden/1.218 tests en geen bekende dependencykwetsbaarheden.

## Core uitgiftenavigatie — 2026-08-14

- Hosted observatie: core-run `31791864580` valideerde exact main/deployattest, beheerder-MFA/settings/mobiel, kledingcommissie-MFA/rolgrens/mobiel en uitgifte-MFA plus app-sessie. De uitgifteflow stopte direct daarna generiek; `always()`-cleanup verwijderde alle tijdelijke fixtures.
- De regressie legt de vereiste volgorde vast: automatische `/uitgifte`-landing en heading, daarna pas `goto(/backoffice)`, server-side redirect terug naar `/uitgifte` en opnieuw de scannerheading. Afzonderlijke tests eisen stabiele foutcodes voor landing en HTTP-/navigatieboundary.
- Exact-main CI, immutable stagingdeploy en een nieuwe coreacceptatie blijven vereist. Production is niet benaderd.
- Volledige lokale kandidaatgate: `pnpm lint`, `pnpm typecheck`, `pnpm lint:workflows`, `pnpm security:secrets`, `pnpm security:migrations`, `pnpm security:dependencies`, `pnpm test` en `pnpm build` zijn groen. Resultaat: 138 migrations, 198 testbestanden/1.220 tests en geen bekende dependencykwetsbaarheden.

## Finale voorraad- en rerunbewijsfix — 2026-08-14

- Exacte mainbasis `911449de3501ce8849ceba8857a05647b7f82a58`: CI-run `31795452332` is volledig groen met 1.220 applicatietests en de volledige database/RLS/concurrencymatrix; deployrun `31795452355` bouwde en activeerde artifactdigest `sha256:90c1c2ba0f3f74ee7d8991ce4e26870ed8b8e0ab806b8570ef6b94627a208ac6`. Core-run `31797714880` is volledig groen.
- Mollie-run `31797514144` bereikte paid zonder allocatie/QR en stopte pas bij de readiness-transactie. Hosted PostgreSQL-logclassificatie gaf tweemaal de PII-vrije code `ACTION_ITEM_DEDUPE_COLLISION`; fixturecleanup en het terugsluiten van de databaseproviderflag slaagden.
- De voorraadregressie voert na twee concurrerende FIFO-allocators twee gelijktijdige refreshes met verschillende operationele bronnen uit. Er resteert exact één actieve `out_of_stock`-episode met bron `article_variant` en de echte variant-ID. Mollie-fixture-SQL en de bestaande action-itemconcurrency blijven groen.
- De upgrade vanaf de productieachtige legacybaseline heeft alle Phase-B-migraties plus `20260814120000_inventory_action_source_stability.sql` toegepast met bytegelijke legacyhashes en groene reconciliatie. De aansluitende schone reset paste alle 139 migrations toe; `pnpm test:db` gaf 54 bestanden/1.757 assertions groen.
- De releasebewijsregressies bewijzen dat oude gelijknamige rerun-artifacts buiten het actuele jobvenster worden behouden en genegeerd, terwijl ontbrekend, verlopen, ongeldig, buiten-venster of dubbel actueel bewijs fail-closed blijft. De staging- en productiepromotieverifiers delen deze grens.
- Volledige lokale herstelgate: ESLint, TypeScript, dependency-audit zonder bekende kwetsbaarheden, secretscan, migrationlint, 198 Vitestbestanden/1.225 tests en production build groen. De officiële exacte-main stagingmatrix en production blijven geblokkeerd tot merge en nieuw immutable kandidaatbewijs.

## Providerrefund uit scope en finale releaseharnasregressies — 2026-08-14

- `pnpm test` — groen: 198 bestanden, 1.227 tests. De nieuwe regressies bewaken dat de Mollie-run geen `changePaymentState`, refundcompletion of refundpoll uitvoert, dat het promotiecontract exact de nieuwe jobnaam gebruikt, dat snapshotdoelbestanden vóór Docker runner-owned worden aangemaakt en dat SendGrid-keyhardening account-/keygebonden plus expliciet bevestigd is.
- `pnpm test:db` — groen: 54 pgTAP-bestanden, 1.757 assertions. RLS, providerreconciliatie, refund/QR-intrekking en maildeliveryledgers blijven ongewijzigd groen.
- `pnpm test:db:mollie-fixture` — groen tegen de echte lokale PostgreSQL-schemaopbouw. De test prepareert twee fictieve orders, enqueue't en claimt een echte mailjob zodat immutable attempt/outcome-state bestaat, maakt een synthetisch actiepunt, voert cleanup uit en bewijst daarna idempotent nul leden, orders, grants, attempts en actiepunten.
- `pnpm lint`, `pnpm typecheck`, `pnpm lint:workflows`, `pnpm build`, `pnpm security:dependencies`, `pnpm security:secrets` en `pnpm security:migrations` — groen; geen bekende dependencykwetsbaarheid en 139 bestaande forward-only migrations ongewijzigd geldig.
- Hosted SendGrid-run `31813739541` bewees na synchronisatie van de keyfingerprint dat key en account correct binden; de provider stopte vervolgens terecht op een te brede runtime-scopelijst vóór mailverzending. De veilige scope-restrictie en daaropvolgende inbox-/signed-eventtest vereisen de nieuwe main-SHA. Er zijn geen secretwaarden of persoonsgegevens vastgelegd en production is niet benaderd.

## Legacy-adoptie Node-bootstrap — 2026-08-15

- Hosted run `31822891227`: trusted-mainpreflight, eenmalige-historiecontrole, productionapproval en productionrunnerboundary groen. De capture stopte vóór `docker save` met de PII-vrije fout `Vereist commando ontbreekt: node`; de always-cleanup slaagde en production bleef runtime-ongewijzigd.
- De gerichte workflowtests vereisen voor productioncapture, stagingadoptie en beide rollbacktargetsynchronisaties een commit-gepinde `actions/setup-node`, Node 22 en de volgorde runnerboundary → Node-bootstrap → Node-afhankelijk script.
- Hosted eindbewijs vereist na merge een nieuwe immutable exact-main stagingdeploy, gevolgd door de eenmalige legacy-adoptie en gewone artifactgebonden rollbackdrill.

## Functionele SendGrid-scopegate — 2026-08-15

- Hosted provider-run `31854323207` valideerde de exacte main-SHA, stagingdigest, key-/accountbinding en cleanup, maar stopte vóór verzending op de voormalige exacte-één-scoperegel. Hardeningrun `31854410712` bond dezelfde key en account en stopte zonder mutatie op provider-HTTP 403 bij de keyupdate.
- De gerichte regressie bewijst dat `mail.send` naast aanvullende scopes doorloopt naar de volledige MFA-, appdelivery-, inbox- en signed-eventflow, terwijl een key zonder `mail.send` vóór verzending wordt geweigerd. De losse scopeworkflow bevat geen `PUT` of API-keyendpoint meer.
- `pnpm exec vitest run scripts/providers/sendgrid-staging-acceptance.test.ts scripts/providers/sendgrid-acceptance-evidence.test.ts` — groen: 17 tests.
- Volledige lokale gate — groen: 198 Vitestbestanden/1.229 tests, ESLint, TypeScript, actionlint, secretscan, 139 forward-only migrations, dependency-audit zonder bekende kwetsbaarheden en production build. Exact Node 22-, main-, immutable staging-, inbox- en signed-eventbewijs volgt via GitHub Actions.
- Legacy-adoptierun `31854456980` stopte na groene trusted-main-, historie-, runner-, Node- en Cosignstappen op `Productionappcontainer ontbreekt`. Publieke read-only probes op `/` en `/api/health` gaven gelijktijdig HTTP 502; cleanup slaagde en productie werd niet gewijzigd.

## SendGrid signed-webhook GET-contract — 2026-08-15

- CI-run `31859488638` en immutable deployrun `31859488625` zijn groen op exact main-SHA `0885f1eae2ce4a220067d2aabc586595c54b26ef`; publieke staginghealth meldt dezelfde SHA en het result-bound artifactdigest.
- Provider-runs `31860835400` en `31860997813` bereikten de read-only account-, scope-, eventselectie- en signingcontrole, maar stopten vóór testmailverzending op `SENDGRID_WEBHOOK_SIGNING_INVALID`. De always-cleanup verwijderde de tijdelijke authfixture in beide runs.
- Configuratierun `31860942511` bewees bij SendGrid dat webhook, eventselectie en signing correct zijn en maakte een nieuwe expliciete publieke-keyhandoff. De resterende fout zat in het harnas: het eiste bij de signed-public-key-GET een `enabled`-veld dat het officiële responsecontract niet bevat.
- De regressietest modelleert nu de officiële response met alleen `id` en `public_key`. De fail-closed controle op webhook-ID, P-256-keytype/-curve en SHA-256-fingerprint blijft behouden. Nieuwe exact-head CI, main-deploy en echte inbox-/signed-eventacceptatie volgen.

## SendGrid staging-sessie requestcontract — 2026-08-15

- Exact-main CI `31862197916`: groen voor applicatiegate, 139 migraties, DB/RLS, concurrency, capaciteit, MFA, recovery, oudertoegang en Playwright op `1050410cca10f720a4913a1df003b1b097df9d9e`.
- Immutable stagingdeploy `31862197844`: groen op dezelfde SHA; publieke health retourneert dezelfde revision en release-artifactdigest.
- Provideracceptatie `31863583992`: key-, account-, webhook- en signed-public-keycontrole groen; sessiesynchronisatie stopte met `E2E_APP_SESSION_HTTP_403` vóór mailverzending; fixturecleanup groen.
- Regressie eist voor de Node-harness exact `Origin`, `Sec-Fetch-Site: same-origin` en `X-Duindorp-CSRF: same-origin` op de app-sessie-POST. De routeguard en zijn fail-closed browsermutatiecontract blijven ongewijzigd.
- Lokaal groen: gerichte provider/evidence-suite 17/17; volledige Vitest-suite 198 bestanden/1.229 tests; ESLint, TypeScript, actionlint, production build, secretscan, 139 forward-only migrationchecks en dependency-audit zonder bekende kwetsbaarheden.

## SendGrid testdelivery- en cleanupcontract — 2026-08-15

- Main-CI `31880856810` en immutable stagingdeploy `31880856818` zijn volledig groen op exact SHA `7dc3cd8376cc7f01943c82625b59476a6a25261d`.
- Provider-run `31886420637`: exact-SHA/digestpreflight en AAL2-appsessie groen; primaire acceptatie plus interne cleanup eindigden als `SENDGRID_ACCEPTANCE_AND_CLEANUP_FAILED`; de afzonderlijke fail-safe cleanup verwijderde de tijdelijke acceptatie-identiteit succesvol.
- Codeanalyse bewijst twee deterministische oorzaken: de testdelivery-POST miste de door `guardBrowserMutation` verplichte fetch-metadata-/CSRF-headers, en lokale sign-out maakte de JWT ongeldig vóór de daaropvolgende globale admin-sign-out. De regressie eist headers op beide idempotente deliveryaanvragen, globale intrekking met de AAL2-JWT en geen voortijdige client-sign-out.
- Legacy-adoptierun `31863584074`: main-/artifact-/historie-/runner-/Node-/Cosigncontrole groen; read-only capture stopte op `Productionappcontainer ontbreekt`; cleanup groen en production ongewijzigd.
- Lokaal groen: gerichte provider/evidence-suite 17/17; volledige Vitest-suite 198 bestanden/1.229 tests; ESLint, TypeScript, actionlint, production build, secretscan, 139 forward-only migrationchecks en dependency-audit zonder bekende kwetsbaarheden.

## SendGrid pre-cutover providerbewijs — 2026-08-15

- Exact-main CI `31887576984` en deploy `31887576958` zijn groen op `f1cef43214e612230829554a550ed2fa3c0307a1`; staginghealth, deployresultaat en result-bound attestatie bewijzen exact hetzelfde artifact.
- Provider-run `31888915556` passeerde provider-, webhook-, signing- en AAL2-sessiecontrole, stopte vóór verzending op de onterechte operationele featureflageis en verwijderde de tijdelijke acceptance-identiteit via de always-cleanup.
- `pnpm exec vitest run scripts/providers/sendgrid-staging-acceptance.test.ts scripts/providers/sendgrid-acceptance-evidence.test.ts` — groen: 24 tests. De succesflow modelleert nu expliciet `featureEnabled: false`; afzonderlijke regressies bewijzen query-, niet-gepubliceerde-template- en ieder afzender-brandingveld zonder providerrequest.
- `pnpm exec node scripts/run-supabase.mjs test db --local supabase/tests/mail_v2_test_delivery.sql` — groen: 47 pgTAP-asserties; de AAL2-beheerder kan een gepubliceerde testdelivery voorbereiden terwijl `mail_templates_v2` expliciet uit staat, en AAL1/kledingcommissie blijven geblokkeerd.
- Volledige lokale gate — groen: 198 Vitestbestanden/1.236 tests, ESLint, TypeScript, actionlint, production build, secretscan, 139 forward-only migrations en dependency-audit zonder bekende kwetsbaarheden.

## Recipient-serveracceptatie en eenmalige legacyprovenance — 2026-08-15

- `pnpm test` — groen: 198 bestanden, 1.242 tests. De suite omvat schema-v2 SendGridobservatie/evidence, expliciete app-HTTP-acceptatie en requestreplay, signed recipient-serverdelivery, MFA/cleanup, promotiecanonicalisatie, twee legacycapturemodi, state-drift, workflowbinding en privacyveilige logredactie.
- `pnpm lint`, `pnpm typecheck`, `pnpm lint:workflows`, `pnpm build`, `pnpm security:dependencies`, `pnpm security:secrets` en `pnpm security:migrations` — groen; nul bekende dependencykwetsbaarheden en 139 forward-only migrations ongewijzigd geldig.
- `bash -n scripts/deploy/capture-legacy-release.sh` en ShellCheck — groen, met uitsluitend de bekende informatieve melding dat de projectspecifieke boundaryhelper niet automatisch wordt gevolgd. De capturetests verbieden Docker build/pull/load/tag/run/create/start/stop/restart/rm/prune en Compose-up.
- Het legacybewijs valideert exact één OCI-manifestdescriptor, de manifestblob, de verwijzing naar de verwachte config, de configblob, iedere layerblob en het releaselabel. Publieke en loopback legacyhealth lopen vóór en na; de gehashte daemon-/manifest-/container-/imagestate moet exact gelijk blijven.
- Een onafhankelijke read-only finale review gaf `GO`: Compose-, daemon- en OCI-inventarisfouten falen gesloten, beide schema-v2-contracten zijn canoniek en promotion/jobnaam/evidencehash zijn consistent. De enige beperking is de expliciet benoemde eenmalige provenance-uitzondering met `live_container_bound=false`.
- Hosted provider-run `31895800773` heeft appacceptatie en idempotente replay daadwerkelijk bereikt; het oude gecombineerde harnas stopte uitsluitend op `E2E_MAILBOX_DELIVERY_TIMEOUT`. De nieuwe hoofd-SHA moet het gekoppelde signed `delivered`-event en finale health nog als canoniek artifactbewijs produceren. Production is niet gemuteerd.

## Catalogusvariant-aliasregressie — 2026-08-16

- `pnpm lint`, `pnpm typecheck`, `pnpm lint:workflows` en `pnpm build` — groen.
- `pnpm test` — groen: 198 bestanden en 1.243 tests, inclusief requestnormalisatie en de catalogusvariant-route.
- `pnpm security:dependencies`, `pnpm security:secrets` en `pnpm security:migrations` — groen; nul bekende dependencykwetsbaarheden en 140 forward-only migraties.
- `pnpm test:dashboard-browser` — groen na een volledige schone replay van alle 140 migraties. De operationele browserflow maakt een variant met maat `164`, code `BROWSER-164` en aliassen `１６４, Browser jeugd 164`; na reload resteert alleen de aanvullende alias en de flow vervolgt alle overige backoffice-, import-, scanner- en securitycontroles.
- `pnpm test:db` — groen bij sequentiële CI-conforme uitvoering: 54 pgTAP-bestanden en 1.763 assertions. `variant_size_aliases.sql` bewijst redundante eigen label-/codealiassen, opslag/audit van alleen de aanvullende alias en blijvende cross-variantblokkade.
- `pnpm test:db:variant-concurrency` — groen; v2 en legacy serialiseren nog steeds op dezelfde productsleutel.
- Een eerdere lokale parallelle combinatie van de volledige pgTAP-suite met de concurrencyfixture gaf bewust geen bewijs: één globale eigenaarstelling zag de gelijktijdige tijdelijke medewerker. De aansluitende sequentiële volledige suite is groen en is het geldige resultaat.
## Flexibele ledenimport en handmatige invoer — 2026-08-16 lokaal

- Schone database-upgrade: alle 141 forward-only migrations zijn vanaf nul drie keer succesvol gereplayed; `20260816034918_member_import_flexibility_manual_create.sql` is telkens vóór seed en containerrestart toegepast.
- Volledige pgTAP: 56 bestanden, 1.782 assertions, groen. Nieuwe bewijzen de service-rolefilter, het niet duurzaam stagen van onbekende maten, niet-blokkerende creatie zonder team, admin+AAL2, private DOB, ontbrekend team, idempotentie, duplicatebevestiging en het ontbreken van order/toegang.
- Volledige Vitest: 199 bestanden, 1.247 tests, groen. Nieuwe route- en workerregressies bewijzen de policybinding, filtering vóór staging, handmatige create, kandidaatresponse, bevestiging en harde externe-ID-blokkade.
- De echte lokale Playwrightflow is groen en heeft via de productiebuild 99 leden geïmporteerd, waaronder één lid zonder team met genegeerde onbekende maat; 98 geldige maten bleven intact. Dezelfde flow heeft een lid zonder team handmatig toegevoegd, private DOB en nul orders bewezen en alle fictieve data plus workerheartbeats weer verwijderd. De direct aansluitende volledige pgTAP-suite bleef groen.
- ESLint, `tsc --noEmit`, production `next build`, `git diff --check`, secretscan en migrationlint (141 migrations) zijn groen.
- Hosted exact-SHA CI, immutable stagingdeploy en echte beheerderbrowseracceptatie volgen na publicatie; productie is niet benaderd of gewijzigd.

## Pakketbulkbeheer voor leden — 2026-08-16 lokaal

- `pnpm db:reset` — groen: alle 142 forward-only migrations, inclusief `20260816053605_member_package_bulk_assignment.sql`, replayen schoon vanaf nul.
- `pnpm test:db` — groen: 57 pgTAP-bestanden en 1.810 assertions. De 28 nieuwe assertions bewijzen geselecteerd en alle actief, confirmed/locked-maatkoppeling, ontbrekende maten zonder gok, soft withdrawal, betalingsguard, actuele projecties, veilige hertoewijzing, RLS/privileges, idempotentie en audit.
- `pnpm test:db:package-concurrency` — groen: pakketselectie, defaults, wissels en maatresoluties serialiseren zonder partial writes; de nieuwe bulk-RPC gebruikt dezelfde deterministische lid-seizoenslocks en een duurzame requestledger.
- `pnpm test` — groen: 202 Vitestbestanden en 1.257 tests, inclusief contract-, previewtoken-, route-, workspace- en UI-integratietests voor individueel, geselecteerd en alle actief.
- `pnpm lint`, `pnpm typecheck`, `pnpm build`, `pnpm lint:workflows`, `pnpm security:dependencies`, `pnpm security:secrets`, `pnpm security:migrations` en `git diff --check` — groen na de finale controle.
- Geen staging- of productiedeploy uitgevoerd. Hosted CI en menselijke browseracceptatie volgen pas na review/merge.

## Pakketbetaling en maatsegmentatie — 2026-08-16 lokaal

- `pnpm db:reset` — groen: alle 143 forward-only migrations, inclusief `20260816061345_package_payment_size_communication.sql`, replayen schoon vanaf nul.
- `pnpm test:db` direct na de schone reset — groen: 57 pgTAP-bestanden en 1.821 assertions. De geïsoleerde sequentiële run is het geldige eindbewijs.
- Gerichte pgTAP-regressie — groen: 39 assertions in `member_package_bulk_assignment.sql`. Bewijst Mollie-prepare zonder maten/regels/voorraad, nul voorraadmutaties, invul- versus controlesegment, wederzijdse suppressie, nul-regelcampagne/eventstate, campagneworkspace en pakketsnapshotfallback in de betaalbevestiging.
- Bestaande mail- en providerregressies — groen: 137 assertions voor campagnes/projectie/reminders plus 131 assertions voor Mollie-providerhardening, legacycompatibiliteit en het nieuwe pakketpad.
- `pnpm test:db:package-concurrency`, `pnpm test:db:payment-concurrency`, `pnpm test:db:mail-campaign-concurrency` en `pnpm test:db:mail-projection-concurrency` — groen; retries, webhook/kas, reminders en gezinsprojectie blijven geserialiseerd en idempotent.
- `pnpm test` — groen: 202 Vitestbestanden en 1.259 tests. De ouder-UI-regressie bewijst directe betaling zonder regels/voorraad, legacyblokkade in de UI en het onderscheid tussen invullen, controleren en bevestigd.
- ESLint, TypeScript, actionlint, production build, dependency-audit, secretscan en lint van 143 forward-only migrations zijn groen. Staging en productie zijn niet gewijzigd.

## FIFO-accordion en levering-PUT — 2026-08-16 lokaal

- `pnpm db:reset` — groen: alle 144 forward-only migrations replayen schoon, inclusief `20260816092543_inventory_waitlist_line_snapshots.sql`.
- `pnpm test:db` — groen: 57 pgTAP-bestanden en 1.823 assertions. De voorraadtest bewijst de product-/maatsnapshots en dat de rol `uitgifte` de nieuwe workspace-RPC niet kan gebruiken.
- `pnpm test:db:inventory-concurrency` — groen: één fysiek stuk geeft exact één journaalevent, de oudste geschikte artikelregel en één stabiele tekortepisode.
- `pnpm test` — groen: 205 Vitestbestanden en 1.267 tests. Nieuwe regressies bewijzen groepering op order-ID, behoud van responsevolgorde, gescheiden naamgenoten, de v2-workspaceaanroep, het hosted PostgREST-preflightcontract en same-origin/cross-origin PUT.
- `pnpm lint`, `pnpm typecheck`, `pnpm build` en `git diff --check` — groen. De Next.js-buildmelding over meerdere lockfiles in de gedeelde worktreeomgeving is informatief en veranderde de succesvolle build niet.
- Geen staging- of productiedeploy uitgevoerd.
- Hosted PR-CI `31939467117`: applicatiejob volledig groen; Supabasejob passeerde migratie-upgrades, schone replay, pgTAP en alle concurrencytests, maar blokkeerde fail-closed op de staging-cleanupinventaris. De ontbrekende operationele tabel `private.member_package_bulk_requests` is daarna expliciet aan het 102-tabellencontract toegevoegd; een exacte rerun blijft vereist vóór merge/deploy.
- Hosted rerun `31939971437` bewees de cleanupfix later in de databasejob, maar de parallelle applicatiejob vond dezelfde nieuwe tabel nog in een tweede expliciete restore-inventaristelling van 129. Die restoreassertie en haar documentatie zijn naar de werkelijke gesloten 130-tabellenset gebracht; de volledige lokale suite en een nieuwe exacte hosted run blijven vereist.

## Geauditeerd ledenbeheer — 2026-08-16 lokaal

- `pnpm db:reset` — groen: alle 146 forward-only migrations, inclusief `20260816122941_member_profile_editing.sql`, replayen schoon vanaf nul.
- `pnpm test:db` — groen: 58 pgTAP-bestanden en 1.860 assertions. De 24 nieuwe assertions bewijzen ingetrokken directe writes, admin+AAL2, actieve versus historische seizoenbinding, private DOB, PII-vrije audit, idempotentie, commissiegrens, ongereserveerde bestelmaat, uitgegeven lock en journal-aware reserveringsvrijgave.
- `pnpm test` — groen: 210 Vitestbestanden en 1.283 tests, inclusief strikte request-/responsecontracten en autorisatie-, validatie- en foutmappingtests voor profiel en maten.
- `pnpm test:e2e` — groen: de productiebuild doorloopt echte AAL2-login, opent `Lid bewerken`, slaat DOB en geslacht op, herlaadt en leest beide terug; desktop, mobiel, import, overige backofficeflows en scanner-PWA blijven groen.
- De cleanup-/restorecontracttests binden de twee nieuwe requestledgers aan exact 105 operationele, 28 behouden en 133 totale app/private-tabellen; onverwachte schema- of inventarisdrift blijft fail-closed.
- `pnpm lint`, `pnpm typecheck`, `pnpm build`, secretscan, migrationlint en `git diff --check` — groen. Stagingacceptatie volgt na exact-SHA merge; productie blijft geblokkeerd tot de afgesproken ouderportaalcopy is verwerkt.

## Liveness/readiness-startcontract — 2026-08-16 lokaal

- Gefaalde hosted deploy `31949963942`: migration `20260816122941_member_profile_editing.sql` en PostgREST-contract groen; kandidaat en rollbackimage startten Next.js, maar Compose blokkeerde beide op de volledige operationele `/api/health` voordat de scheduler kon starten.

- `pnpm exec vitest run src/app/api/live/route.test.ts scripts/deploy/deployment-contract.test.ts` — groen: 2 bestanden, 32 tests. Bewijst minimale PII-vrije liveness, Composebinding uitsluitend aan `/api/live` en behoud van twee volledige readinesschecks met begrensde herstelwachttijd.
- Volledige lokale gate — groen: 211 Vitestbestanden/1.284 tests, ESLint, TypeScript, production build, dependency-audit zonder bekende kwetsbaarheden, secretscan, lint van 146 forward-only migrations en `git diff --check`. Hosted exact-main CI en immutable stagingredeploy volgen op de herstelcommit.

## OTP-readiness en rollbackcompatibiliteit — 2026-08-16

- Read-only stagingdiagnose op uitsluitend geaggregeerde healthvelden: twee recente `configuration_error`-uitkomsten; nul provider rejection/render failure, nul delivery uncertainty, nul bounce/drop/failure, nul quarantaine, nul mailqueuefout, nul importfout, nul brandingblocker en nul reconciliatieverschil. De kandidaatworker had alle vier operationele jobs succesvol uitgevoerd.
- `pnpm db:reset` — groen: alle 147 forward-only migrations, inclusief `20260816151112_resolve_recovered_parent_otp_health.sql`, replayen schoon vanaf nul.
- `pnpm test:db` — groen: 58 pgTAP-bestanden en 1.864 assertions. Nieuwe assertions bewijzen service-only health v13, blijvend blokkeren van echte providerafwijzing en het niet dubbel blokkeren op een bewaarde historische runtimeconfiguratiefout.
- `pnpm test` — groen: 211 Vitestbestanden en 1.284 tests.
- `pnpm lint`, `pnpm typecheck`, `pnpm lint:workflows`, `pnpm security:secrets`, `pnpm security:dependencies` en `pnpm security:migrations` — groen; dependency-audit meldt geen bekende kwetsbaarheden en migrationlint controleert 147 bestanden.
- `pnpm build` — groen: production build bevat de ledeneditor, `/api/live`, health v13 en alle drie applicatieoppervlakken.
- Composecontracttest bewijst dat actuele images uitsluitend `/api/live` gebruiken en dat de hoofdpaginafallback alleen bij exact HTTP 404 van een vorige image wordt gebruikt; `/api/health` blijft buiten Dockerliveness en binnen de latere harde deploygate.

## Ledenreview ouderportaalcopy — 2026-08-16 lokaal

- `pnpm exec vitest run src/components/member/member-dashboard.test.ts src/app/api/parent/packages/select/route.test.ts src/app/api/parent/packages/sizes/route.test.ts src/server/email/mail-v2.test.ts src/server/email/otp.test.ts src/app/api/parent-auth/request-code/route.test.ts` — groen: 6 bestanden en 33 tests. Bewijst ouderdashboard-, pakket-/maatroute- en OTP-rendercontracten.
- `pnpm db:reset` — groen: alle 148 forward-only migrations replayen schoon, inclusief `20260816162413_align_parent_portal_copy.sql`; veilige metadatacontrole bewijst het nieuwe OTP-onderwerp en een geldige herberekende content-hash zonder persoonsgegevens of secretwaarden uit te lezen.
- `node scripts/check-migrations.mjs`, `pnpm lint`, `pnpm typecheck`, `pnpm build` en `git diff --check` — groen. Op verzoek is de volledige lokale testmatrix niet opnieuw uitgevoerd; de verplichte hosted exact-main releaseketen blijft onverkort gelden.
- Hosted PR-run `31958760837`: applicatiejob volledig groen met 211 bestanden/1.284 tests. De databasejob vond een hardcoded verwachte OTP-templateversie in `email_template_parent_otp.sql`; na versie-onafhankelijke correctie is het gerichte pgTAP-bestand lokaal groen met 11/11 assertions en volgt een nieuwe volledige hosted run.

## Production recovery-point bronmajor — 2026-08-17 lokaal

- Productiepromotie `32013385839`: exacte evidencevalidatie, kandidaatcapture, runnerboundary, Supabase CLI, GitHub CLI, Cosign, evidence-download, herverificatie en rollbackbinding groen. `Create, encrypt and isolated-restore the production recovery point` stopte vóór backupupload/migratie/deploy; cleanup was groen en productie bleef ongewijzigd.
- `pnpm exec vitest run scripts/staging/validate-source-restore-inventory.test.ts scripts/staging/write-restore-evidence.test.ts scripts/deploy/production-backup-evidence.test.ts scripts/staging/cleanup-operational-data.test.ts scripts/staging/validate-target.test.ts` — groen: 5 bestanden, 76 tests.
- De regressies bewijzen een ondersteunde major-15-legacybron naar exact major-17-herstel, weigeren major 14/18 en een oudere stagingbron, bewaren exacte schema-/ACL-/RLS-/data-HMAC-controle en valideren het gebonden versleutelde productiebackupbewijs schema v5.
- `bash -n scripts/staging/restore-drill.sh scripts/staging/create-source-snapshot-backup.sh` en gerichte ESLint — groen. Hosted exact-main CI, stagingrestore en productie-recoverypoint blijven vereist.

## Publieke stagingorigin-cutover — 2026-08-17 lokaal

- Alle 36 repositoryreferenties naar de voormalige stagingorigin zijn samen naar `https://duindorpsv.dgwebservices.nl` gebracht; de productionorigin en poort `24000` zijn ongewijzigd.
- Gerichte Vitestregressie: 13 bestanden en 165 tests groen voor deploy-, health-, provider-, stagingtarget- en Host/edgecontracten.
- `pnpm typecheck`, shell-/Node-syntax, gerichte ESLint en `git diff --check` zijn groen. Op verzoek zijn volledige build-, browser- en databasesuites niet lokaal herhaald; exact-main CI en de immutable stagingdeployment blijven de hosted poort.

## Hostgebonden live-Mollie-runtime — 2026-08-17 lokaal

- Deployrun `32060172912` bouwde en signeerde exact main `ec92b3f`, maar stopte vóór iedere stagingmutatie omdat de actuele Mollie-key niet aan de eerdere staging-testprefix voldeed.
- `scripts/deploy/deployment-contract.test.ts` — groen: 32 tests. De nieuwe regressie accepteert een live key op exact de publieke cluborigin en weigert een onbekende keyvorm; productionisolatie en test-only Mollie-acceptatie blijven intact.
- `pnpm typecheck`, gerichte ESLint, Node-syntax en `git diff --check` zijn groen. De volledige hosted poort blijft verplicht vóór redeploy.

## Dynamische-importleaseherstel — 2026-08-18 lokaal

- Schone replay van alle 149 forward-only migrations is groen, inclusief `20260817231704_refresh_dynamic_import_lease_clock.sql`.
- `supabase/tests/dynamic_import_operations.sql` — groen: 35 assertions, waaronder de wall-clockvloer, service-only leasevrijgave en weigering van een vreemde claimtoken.
- `pnpm test:db:import-concurrency` — groen: parallel claimen, fencing, identiteit en lockvolgorde blijven intact.
- `src/app/api/internal/jobs/imports/route.test.ts` — groen: 15 tests; één kleine commitchunk per invocation en een oude gefencete lease eindigt hervatbaar zonder runfailure/finalizer.
- Gerichte ESLint, TypeScript, migrationlint, secretscan, security- en performance-advisors en `git diff --check` zijn groen.
- `scripts/test-dynamic-import-browser.mjs` — groen op de productiebuild: preview, hervatting over meerdere begrensde worker-aanroepen, commit van 101 rijen, DOB, conflictsuppressie en handmatige invoer.

## OTP-mailcontract en mailpadaudit — 2026-08-18 lokaal

- `pnpm vitest run src/server/email src/lib/email-contract.test.ts src/lib/mail-v2-contract.test.ts src/app/api/parent-auth/request-code/route.test.ts src/app/api/internal/jobs/email/route.test.ts src/app/api/email` — groen: 26 bestanden en 143 tests. Dit omvat OTP, SendGrid, webhook, alle mail-v2-services, worker en e-mailroutes.
- `pnpm vitest run src/app/api/staff-auth/password-recovery/route.test.ts` — groen: 3 tests voor neutrale responses, rate limits en de canonical recoveryredirect.
- Gerichte ESLint op de twee gewijzigde OTP-routebestanden, volledige TypeScriptcontrole en `git diff --check` zijn groen.
- De regressie verwacht nu expliciet dat `preheader` niet aan `sendParentOtpV2Email` wordt doorgegeven. Queue-, fulfilment-, generieke v2- en beheertestmail behouden hun reeds expliciete providerpayload.
- Read-only stagingbewijs: 19/19 templates gepubliceerd en producers actief; queue/retry/failed/uncertain alle nul; vijf portaaluitnodigingen provider-geaccepteerd; twee echte OTP-attempts vóór de hotfix beide `configuration_error` en zonder provider-event. Er zijn in deze lokale fase geen mails verstuurd en geen staging- of productie-instellingen gewijzigd.

## Importworker-runledger en runtime-CVE-gate — 2026-08-18 lokaal

- `pnpm exec vitest run src/app/api/internal/jobs/imports/route.test.ts scripts/deploy/deployment-contract.test.ts` — groen: 2 bestanden en 49 tests. De regressies bewijzen dat disabled/ongeldige configuratie geen ledger opent, false/rejected start geen onbevestigde run afsluit en een fout na bevestigde start wel gecontroleerd wordt gesloten.
- Trivy `0.70.0` tegen de actuele digest `gcr.io/distroless/nodejs22-debian13:nonroot@sha256:939d6f1671529d230f50b563578e9b5d206af58f038b10ebd7e1233023d4e167` vindt exact één HIGH en nul CRITICAL: `CVE-2026-14456` in `libssl3t64@3.5.6-1~deb13u2`, status `fix_deferred`, zonder fixed version.
- De pakket- en vervaldatumgebonden ignorefile onderdrukt lokaal exact die ene bevinding en rapporteert haar zichtbaar als suppressed; dezelfde scan eindigt met nul niet-onderdrukte HIGH/CRITICAL. Vervaldatum is 1 september 2026 en de workflowtest bewaakt exact één CVE, de volledige PURL, behoud van `ignore-unfixed: false` en expliciete workflowbinding.
## Ouderportaal-LiveChat en workspace-nullnormalisatie — 2026-08-18 lokaal

- `pnpm exec vitest run src/components/member/parent-live-chat.test.tsx src/server/security/headers.test.ts` — groen: 2 bestanden en 7 tests. Bewijst expliciete activatie, de aangeleverde licentie/integratie, afwezigheid van portaal-PII en parent-only CSP zonder production `unsafe-eval`.
- `pnpm typecheck`, gerichte ESLint, secretscan, migrationlint voor 153 forward-only migrations en `git diff --check` — groen.
- De centrale v6-SQL is vóór opname als forward-only migration read-only vergeleken met de stagingdefinitie; de eerdere stagingprobe bewees nul null/non-boolean `issued`-waarden en ongewijzigde overige workspace-JSON. Hosted exact-SHA build-, database- en browseracceptatie blijven de releasepoort.

## PostgreSQL-retrystormcontainment — 2026-08-18

- Staging vóór containment: 12.421.916 rollbacks; individuele PostgREST-backends hadden miljoenen sessieregels. De twee foutfuncties gebruikten aantoonbaar SQLSTATE `40001` voor normale pending/terminal state.
- Staging na containment: rollbackdelta 0 over 80 seconden, 0 blocked, 0 idle-aborted, 0 actieve queries langer dan 10 seconden en reguliere RPC-/healthresponses 200. Er zijn geen domeinrecords verwijderd of gewijzigd en de service-role-ACL bleef intact.
- De drie nieuwe migrations zijn lokaal incrementeel toegepast. Vier gerichte pgTAP-bestanden zijn groen met 164 assertions voor queue-, OTP-, mail-test- en operation-runcontracten.
- De gerichte Vitests zijn groen met 4 bestanden/17 tests, inclusief zowel compatibiliteit met de oude `40001`-response als het nieuwe getypeerde pendingpad en de LiveChat/CSP-contracten.
- De afsluitende volledige Vitestsuite is groen met 213 bestanden/1.304 tests; ESLint, TypeScript, production build, secretscan, migrationlint en `git diff --check` zijn eveneens groen.

## Herstelde OTP-providerreadiness — 2026-08-18

- Read-only stagingdiagnose: alle database-, QR-, import-, reminder-, branding- en supplier-readinessassen waren gezond; uitsluitend vijf bewaarde `provider_rejected`-uitkomsten hielden health rood terwijl de payloadcorrectie nog niet kon worden gedeployed.
- De forward-only healthmigratie bewaart alle auditfeiten en telt een HTTP-providerafwijzing alleen als onhersteld wanneer er nog geen latere `accepted`-uitkomst bestaat. Render-, uncertainty-, callbackfailure- en quarantaineassen blijven ongewijzigd fail-closed.
- `supabase/tests/parent_otp_mail_v2.sql` bewijst zowel de blokkade vóór herstel als het vrijgeven na een latere echte provideracceptatie.
- Een afzonderlijke immutable migratiereconciliatie vormt de eenmalige herstelgrens voor de al bekende vóór-de-fix stagingafwijzingen. Dezelfde regressie maakt na die grens een nieuwe afwijzing aan en bewijst dat die nog steeds blokkeert.

## Schedulerhealth na hersteld mailincident — 2026-08-18

- Read-only stagingdiagnose na deploypoging 3: email-, inventory- en retentionjobs slaagden; import was bewust paused/200. Alleen `/api/internal/health` retourneerde 503 op 113 pre-fix failed jobs, drie pre-fix uncertain jobs, drie pre-fix providerfailures en één oude running-run waar meerdere latere successen op volgden.
- De gerichte pgTAP-regressie bewijst dat een later succes de stale-runstatus herstelt en dat een nieuwe failed job ná de migratiegrens nog steeds releaseblokkerend zichtbaar is.

## Tijdelijke SMTP-provider (2026-08-19)

- Lokale adaptertests dekken geldige configuratie, ontbrekende configuratie, 535-auth, 421/450/451/452-retry, 5xx-reject, pre-DATA timeout, DATA-onzekerheid, acceptatie/messageId en fail-closed providerselectie zonder SendGrid-aanroep.
- Een echte SMTP verify/auth en smoke zijn niet uitgevoerd: de vereiste mailboxcredentials zijn terecht niet aanwezig in de repositoryomgeving.

## SMTP-reviewcorrecties (2026-08-19 lokaal)

- De deploymentcontracttest bewaakt dat staging tijdelijk SMTP als default gebruikt zolang SendGrid stuk is; productie blijft zonder expliciete override SendGrid selecteren en levert de verplichte provider- en bulkvariabelen door.
- De e-mailworkertest vult bewust zowel SMTP- als SendGrid-afzendervelden en bewijst dat een actieve SendGrid-provider uitsluitend de SendGrid-identiteit gebruikt.
- De migratie behoudt expliciet `execute` voor `service_role` op zowel claim-v4 (rollbackcompatibiliteit) als claim-v5.

## Assignmentgebonden kledingmaten — 2026-08-19

- De volledige Vitestsuite is groen, inclusief regressies voor de onafhankelijke betaal- en maatassen, een permanent geweigerde ouderpakketmutatie en de parent-workspace v7-binding.
- ESLint, TypeScript en migrationlint zijn groen. De lokale Supabase-start kon in deze omgeving niet worden uitgevoerd omdat geen Docker-daemon beschikbaar is; de database-/pgTAPacceptatie blijft daarom een omgevingsbeperking en geen uitgevoerde productieactie.
- Reviewherstel: de extra bevestigingsguard is verwijderd zodat de bestaande domeinworkflow vóór reservering vrij herbevestigt en na reservering een wijzigingsverzoek/actiepunt vastlegt. Profielen zonder assignment behouden hun bestaande artikelprojectie en betaling blijft canoniek onafhankelijk van maatbevestiging.

## Same-SHA stagingrollbackidentiteit — 2026-08-19

- De deploymentcontracttest bewaakt dat vorige manifest- en imagedigestvalidatie plus de geverifieerde rollbackalias vóór `docker load` staan, dat kandidaat- en rollbacktags ook bij dezelfde SHA gescheiden blijven en dat automatische rollback uitsluitend de alias gebruikt.
- Dezelfde regressie bewaakt dat een digestafwijking vóór aliascreatie en candidate-load fail-closed stopt, dat kandidaat-schedulerlogs behouden blijven en dat aliascleanup pas na volledige acceptatie gebeurt met behoud van de onmiddellijk vorige target.

## Pakketmaat-/betaallifecycle — 2026-08-19

Stagingcontrole na deploy (uitsluitend lezen):

```sql
select o.id, private.package_fulfilment_quantities(o.id)
from app.member_orders o
where o.package_assignment_state = 'active'
  and exists (select 1 from app.payments p where p.order_id=o.id and p.status='paid')
  and o.order_status = 'Afgerond'
  and (private.package_fulfilment_quantities(o.id)->>'pickedUpQuantity')::int
      < (private.package_fulfilment_quantities(o.id)->>'expectedQuantity')::int;

select i.snapshot_id, i.id, count(l.id)
from app.order_package_snapshot_items i
left join app.order_lines l on l.id=i.order_line_id and l.status <> 'cancelled'
group by i.snapshot_id, i.id having count(l.id) > 1;

select metrics from private.migration_reconciliations
where migration_key='20260819130000_package_size_payment_lifecycle';
```

De eerste twee queries moeten nul rijen opleveren. De metrics bewijzen `paidOrdersDetected`, `paidOrdersReconciled`, `paidOrdersReviewRequired`, `orderLinesMaterialized` en `snapshotItemsLinked`. Iedere review vereist beoordeling van de ordergebonden `package_lifecycle.review_required`-audit vóór rolloutacceptatie.

## Database-review regressies — 2026-08-20

- `member_package_bulk_assignment.sql` verwacht `PACKAGE_SIZES_REQUIRED` en nul payments/regels bij ontbrekende én bij complete maar onbevestigde imports. Na expliciete ouderbevestiging bewijst dezelfde test echte ouderprovenance, twee assignmentselecties, componentregels met totale entitlementquantity drie, snapshotlinks en retry zonder dubbele confirmation/payment.
- De follow-up bewaart bestaande provider-, export- en manual-paymenttests voor loose orders en de brede `other`-remindersemantiek, terwijl de parent workspace de strikte variantgereedheid projecteert.
- Reconciliatiemetrics staan onder `20260820100000_package_lifecycle_db_review_fixes`: `paidOrdersDetected`, `paidOrdersReconciled`, `paidOrdersReviewRequired`, `orderLinesMaterialized` en `snapshotItemsLinked`.

Lokale acceptatie op 20 augustus 2026:

- `pnpm db:reset`: groen; alle 160 forward-only migrations en seed zijn op een schone database toegepast.
- `pnpm test:db:upgrade:phase-b`: groen; legacyfingerprints voor geld, voorraad, uitgifte en toegang bleven exact gelijk.
- `pnpm test:db`: groen; 58 pgTAP-bestanden met 1.897 assertions.
- Package-, payment- en inventory-action-upgradeconcurrency: groen.
- `pnpm lint`, `pnpm typecheck`, `pnpm test` (215 bestanden, 1.325 tests) en `pnpm build`: groen.
- Migratie- en secretscan: groen. De aanvullende lokale `supabase db lint` meldt één reeds bestaande fout in `app.assign_legacy_inventory_balance` uit migratie `20260802264000`; de lifecyclewijzigingen zelf leveren geen lintbevinding op en de inventory-upgradegate blijft groen.

## Privacyveilige staging-healthdiagnose — 2026-08-20 lokaal

- `pnpm vitest run scripts/operations/scheduler.test.mjs`: groen; 10 tests bewijzen onder meer dat een private health-503 de vaste operationele velden logt en onbekende velden, e-mailadressen en secrets uitsluit.
- `pnpm lint`, `pnpm typecheck`, volledige `pnpm test` (215 bestanden, 1.326 tests), `pnpm build` en `git diff --check`: groen.
- Hosted deployrun `32363318920` bewees tweemaal dat migraties en appstart slagen maar de scheduler fail-closed blijft op `INTERNAL_HEALTH_HTTP_503`. De vorige publieke app werd teruggezet; de diagnosehotfix muteert geen stagingdata.

## Veilige terminale mailjobs en releasehealth — 2026-08-20

- Hosted diagnose-run `32369319530`: migrations, PostgREST-contract, appstart en publieke routeprobes groen; kandidaat daarna correct teruggerold op private health. De gewhiteliste snapshot toonde uitsluitend `emailJobs.failed = 10`, met alle overige operationele tellers/booleans gezond.
- `pnpm db:reset`: groen; alle 162 forward-only migrations plus seed zijn op een schone database toegepast.
- `pnpm test:db`: groen; 58 pgTAP-bestanden en 1.898 assertions. De gerichte `email_recovery_operations.sql`-regressie bewijst dat alle vijf benoemde veilige pre-send stopredenen niet blokkeren, een revocatie geen intern incident opent en een gewone nieuwe `failed`-job na de herstelgrens wel blijft blokkeren.
- `pnpm test:db:upgrade:phase-b`: groen; legacyhashes en alle reconciliatieasserties bleven gelijk.
- `pnpm lint`, `pnpm typecheck`, volledige `pnpm test` (215 bestanden, 1.326 tests), `pnpm build`, migrationlint voor 161 migrations, secretscan en `git diff --check`: groen.
- Hosted deployrun `32374592108` reduceerde de privacyveilige teller van tien naar één en rolde terecht terug. De overblijvende code is de expliciete legacy-revocatiereden; de tweede migration wijzigt geen job- of auditrij en houdt onbekende/echte failures blokkerend.
- Opvolgende lokale gates: `pnpm lint`, `pnpm typecheck`, volledige `pnpm test` (215 bestanden, 1.326 tests), migrationlint voor 162 migrations, secretscan en `git diff --check`: groen.

## Pre-release mailfailure-herstelgrens — 2026-08-20

- Exact-main CI-run `32380057053` was volledig groen: applicatiequality, schone migratieketen, 58 pgTAP-bestanden, alle concurrencyharnassen, capaciteit/latentie en Playwright.
- Deployrun `32380056799` bewees een gezonde app, toegepaste migration `20260820141000`, HTTP 200 op exact kandidaat-SHA en uitsluitend `emailJobs.failed = 1`; de workflow rolde fail-closed terug en wijzigde de databasemigraties niet terug.
- De aanvullende pgTAP-regressie legt één exacte job-ID/`updated_at`-versie vast: alleen die versie blijft bewaard met health nul; een latere failureversie van dezelfde job telt weer één. Uncertain/providerassen behouden hun eerdere grens en de vijf benoemde pre-send stops blijven afzonderlijk uitgesloten.
- Lokale gates: schone reset met alle 163 migrations en seed groen; 58 pgTAP-bestanden/1.901 assertions groen; Phase-B legacy-upgradehashes en reconciliaties groen; ESLint, TypeScript, 215 Vitest-bestanden/1.326 tests, productiebuild, migrationlint, secretscan en `git diff --check` groen.

## Retention-runhealth — 2026-08-20

- Deployrun `32387896670` paste de gevalideerde mailjobreconciliatie toe en rapporteerde daarna `emailJobs.failed = 0`; uitsluitend `operations.retention.runningStale = true` bleef rood terwijl `lastStatus = succeeded` en `stale = false` waren.
- De gerichte pgTAP-regressie bewaart een oude running-run en bewijst health `false` na een later gestarte succesvolle run; een tweede running-run blijft bij een overlappende, eerder gestarte succesrun opnieuw `true`.
- Lokale gates: schone reset met alle 164 migrations en seed groen; 58 pgTAP-bestanden/1.903 assertions groen; Phase-B legacy-upgradehashes en reconciliaties groen; ESLint, TypeScript, 215 Vitest-bestanden/1.326 tests, productiebuild, migrationlint, secretscan en `git diff --check` groen.

## Gezinsbrede ouder-e-mailtransfer — 2026-08-20 lokaal

- Forward-only migration `20260820214229_family_parent_email_transfer.sql` replayde op een schone lokale database. De gerichte pgTAP-suite bevat 39 groene assertions voor één/meer kinderen, portal-afgeleide familiegrens, uitsluiting van gelijke losse e-mails en historie, doelaccount-/grantreuse, sessie/OTP, directe doeltoegang, Mail-v2-groepering, idempotentie, detailweergave, een echte gegroepeerde mismatchrapportage en rolgrenzen.
- Gerichte TypeScript-/routecontracttests zijn groen: 4 bestanden en 22 tests voor strikt preflight-/applycontract, beheerdergrens, revisionconflict en responsevalidatie.
- Privacyveilige read-only stagingnulmeting op release `d3b54806b1382bda8245964052f758782830182a` (deployrun `32395036159`): 253 geautoriseerde gezinnen, 293 geautoriseerde kinderen, 0 inconsistente gezinnen en 0 afwijkende kinderen. Na de featuredeployment wordt dezelfde aggregate opnieuw aan de exacte live SHA gebonden; details blijven uitsluitend via de AAL2-RPC zichtbaar.
- De eerste volledige pgTAP-run vond één bewuste legacy-auditcontractafwijking (`portalAccessUnchanged` ontbrak bij een gewone niet-portalwijziging). De forward migration behoudt dat veld naast de nieuwe transferstatus. De afsluitende schone rerun is groen: 59 pgTAP-bestanden en 1.942 assertions.
- Alle 19 databaseconcurrencyharnassen zijn groen, inclusief gezins-e-mailtransfer, oudertoegang, OTP, mailprojectie/-supersession, import, voorraad, betaling en refund. Phase-B- en inventory-upgradereconciliaties, de Mollie-fixture, stagingcleanup van 110 operationele tabellen en capaciteit op 1.500 leden/10.000 orderregels zijn eveneens groen.
- `pnpm lint:workflows`, `pnpm lint`, `pnpm typecheck`, volledige `pnpm test` (216 bestanden, 1.331 tests), `pnpm test:edge-proxy`, productiebuild met lokale Supabase-buildbinding en `pnpm test:edge-runtime` zijn groen.
- Echte browseracceptatie is groen voor staff-MFA, wachtwoordherstel, ouderportaaltoegang en de volledige Playwrightreview van backoffice, dynamische import, scanner-PWA, mobiel, toetsenbord, reduced motion en geautomatiseerde toegankelijkheidscontrole.

## Accountloze doelgrant bij gezins-e-mailtransfer — 2026-08-21 lokaal

- De gerichte regressiefixture gebruikt een bestaand doelaccount naast een `pending_account`-grant met hetzelfde doeladres en `parent_account_id = null`; dit is de eerder ontbrekende productie-achtige vorm. De transfer hergebruikt exact die grant-ID, bindt haar aan het doelaccount, behoudt één actieve grant en voltooit de activatiebatch.
- `pnpm exec supabase migration up --local`: forward-only migration `20260821113000` toegepast op de bestaande lokale keten.
- `pnpm exec supabase test db --local supabase/tests/family_parent_email_transfer.sql`: groen, 46 assertions, inclusief een echte oude queued uitnodiging die zonder intern incident of actiepunt veilig wordt beëindigd.
- `pnpm vitest run src/app/api/members/profile/route.test.ts src/app/api/members/profile/email-preflight/route.test.ts src/lib/member-profile-contract.test.ts`: groen, 3 bestanden en 13 tests.
- Schone `pnpm exec supabase db reset --local`: groen, alle 166 forward-only migrations en seed toegepast. De volledige pgTAP-suite is groen: 59 bestanden en 1.949 assertions; het gezins-e-mailconcurrencyharnas bewijst opnieuw één commit, één stale loser en één consistente familie.
- `pnpm lint`, `pnpm typecheck`, volledige `pnpm test` (216 bestanden, 1.333 tests), productiebuild, `pnpm security:migrations`, `pnpm security:secrets` en `git diff --check`: groen.
