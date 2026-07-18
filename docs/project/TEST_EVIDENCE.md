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
- Echte migratie-uitvoering, RLS-negatieve tests en gelijktijdige database-uitgiftetest blijven pending omdat de lokale Supabase runtime ontbreekt.
- Parent QR migration `20260718001000_parent_qr_version.sql` geeft uitsluitend de actieve tokenversie terug aan de service-role RPC; de bearerwaarde wordt server-side afgeleid en als QR-data-URL uitsluitend binnen de geautoriseerde ouderresponse geleverd.
- `qrcode@1.5.4` en de bijbehorende typen zijn projectlokaal gepind; geen externe QR-renderdienst of tracking-URL wordt gebruikt.
- `/qr` buildt als neutrale publieke pagina zonder lid-, order- of betaalgegevens.
- Na ouder-QR-integratie: `pnpm test` (19 passed), `pnpm lint`, `pnpm typecheck` en `pnpm build` — passed.
