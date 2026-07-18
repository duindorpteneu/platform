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
