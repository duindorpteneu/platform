# Test evidence

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
