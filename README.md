# Duindorp SV Tenueportaal

Het Duindorp SV Tenueportaal is één Next.js-applicatie voor backoffice, het ledenportaal en de uitgifte van clubtenues. De MVP beheert leden, orders en exacte betalingen per lid, deelleveringen, één seizoensgebonden QR-code en transactionele e-mail- en betaalproviderflows.

De bindende productbaseline staat in [MVP Canon v1.0](docs/canon/Duindorp_SV_Tenueportaal_MVP_Canon_v1.0.pdf) en [AGENTS.md](AGENTS.md). Dit is een Duindorp SV-product, geen generiek of multi-tenant SaaS-platform.

## Stack

- Next.js App Router, React en TypeScript
- Tailwind CSS en gedeelde Duindorp SV-componenten
- Supabase PostgreSQL, RLS, Storage en medewerkersauthenticatie met TOTP/AAL2
- Custom ouder-OTP en gehashte, herroepbare oudersessies
- Mollie en SendGrid achter server-side safety switches
- Vitest, pgTAP en Playwright
- pnpm 11.5.2 en Node.js 22

## Lokaal starten

Vereisten: Node.js 22, pnpm via Corepack en Docker.

```bash
cp .env.local.example .env.local
corepack enable
pnpm install --frozen-lockfile
pnpm supabase:start
pnpm exec supabase status
```

Neem alleen de lokale publishable en secret key uit `supabase status` over in het niet-gecommitte `.env.local`. Vul unieke lokale waarden van minimaal 32 tekens voor `PARENT_TOKEN_PEPPER` en minimaal 16 tekens voor `CRON_SECRET` in. Externe providers blijven lokaal standaard uit.

```bash
pnpm db:reset
pnpm dev -- --port 3100
```

De app draait op [http://localhost:3100](http://localhost:3100). De geïsoleerde lokale Supabase-poorten en opruiminstructies staan in [LOCAL_DEVELOPMENT.md](docs/project/LOCAL_DEVELOPMENT.md). Stop uitsluitend deze projectstack met `pnpm supabase:stop`.

## Quality gates

```bash
node scripts/check-secrets.mjs
node scripts/check-migrations.mjs
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

Met een actieve, schone lokale Supabase-stack:

```bash
pnpm db:reset
pnpm test:db
pnpm test:db:concurrency
pnpm test:staff-mfa
pnpm test:e2e
```

De CI voert locked installatie, secret scan, migration lint, lint, typecheck, tests, productiebuild, schone migratie en pgTAP/RLS-tests uit. Een groene lokale of CI-run is nog geen stagingacceptatie.

## Omgevingen en release

- [Omgevingsmatrix](docs/project/ENVIRONMENT_MATRIX.md) — harde scheiding tussen local, staging en production.
- [Operationsrunbook](docs/project/OPERATIONS_RUNBOOK.md) — monitoring, cron, back-up/herstel, providerflags, keyrotatie en incidenten.
- [Releasechecklist](docs/project/RELEASE_CHECKLIST.md) — lokale, staging- en productiepoorten.
- [VPS-deployment](docs/project/VPS_DEPLOYMENT.md) — self-hosted runners, GitHub-configuratie, Supabase-migraties, systemd en Caddy-isolatie naast andere projecten.
- [Stagingverificatie](docs/project/STAGING_VERIFICATION.md) — alle achttien canonieke E2E-scenario’s en bewijsvelden.
- [Securityacceptatie](docs/project/SECURITY_ACCEPTANCE.md) — autorisatie-, request-, provider- en privacycontroles.

Live Mollie-testmode, SendGrid-domein/delivery en publiek bereikbare HTTPS-webhooks worden uitsluitend in staging geverifieerd. Productie vereist daarna een afzonderlijke expliciete goedkeuring en release-tag; dit repositorywerk voert geen deployment of productieactie uit.

## Veilig werken

- Commit nooit `.env.local`, credentials, productiedumps of persoonsgegevens.
- Gebruik uitsluitend fictieve `example.invalid`-testdata buiten productie.
- Kopieer productiedata niet naar staging zonder aantoonbare anonimisering.
- Wijzig een reeds toegepaste migratie niet; voeg een forward-fixmigratie toe.
- Providerverkeer vereist zowel de runtimeflag als de gelijknamige beheerde databaseswitch; andere featureflags zijn niet toegestaan.
