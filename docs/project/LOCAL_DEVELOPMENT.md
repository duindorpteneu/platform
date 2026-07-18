# Lokale ontwikkeling

## Vereisten

- Docker met een actieve daemon.
- Node.js en Corepack/pnpm volgens `package.json`.
- Geen globale Supabase-installatie; CLI `2.109.1` is projectlokaal gepind.

## Geïsoleerde services

| Service | Lokale poort |
|---|---:|
| Supabase API | 54329 |
| PostgreSQL | 54339 |
| Supabase Studio | 54349 |
| Mailpit | 54359 |
| Analytics | 54369 |
| Next.js | 3100 |

Alle Supabase-containers en volumes gebruiken project-id `duindorp-tenueportaal-local`. Stop of wijzig geen containers van andere repositories.

De lokale Supabase CLI publiceert ontwikkelpoorten op alle hostinterfaces en Studio/pgMeta hebben lokaal geen eigen login. Gebruik deze stack daarom uitsluitend op een afgeschermde ontwikkelserver, stel de poorten niet publiek open en voer `pnpm supabase:stop` uit wanneer er niet actief aan dit project wordt gewerkt.

## Eerste start

```bash
pnpm install --frozen-lockfile
pnpm supabase:start
cp .env.local.example .env.local
```

Voer daarna lokaal `pnpm exec supabase status` uit en kopieer alleen de lokale publishable/secret key naar het niet-gecommitte `.env.local`. Plak statusoutput niet in logs of documentatie: die bevat lokale credentials.

## Databasekwaliteit

```bash
pnpm db:reset
pnpm test:db
pnpm test:db:concurrency
pnpm test:staff-mfa
```

- `db:reset` wist uitsluitend de lokale Duindorp-database, voert alle migrations opnieuw uit en laadt fictieve seeddata.
- `test:db` voert pgTAP-tests uit voor RLS, rollen, voorraad, QR en deeluitgifte.
- `test:db:concurrency` opent twee echte PostgreSQL-sessies en bewijst dat slechts één balie dezelfde artikelregel kan uitgeven.
- `test:staff-mfa` maakt tijdelijk een fictief account en profiel, bewijst wachtwoordlogin, TOTP-promotie naar AAL2, AAL1-weigering en verwijdert de fixture altijd weer.

De lokale Auth-config heeft TOTP enrollment en verificatie expliciet aan. Het Data API exposeert `app` voor RLS- en RPC-gecontroleerde applicatietoegang; `private` blijft niet-exposed.

## Stoppen

```bash
pnpm supabase:stop
```

De projectdata blijven daarbij in het uitsluitend voor Duindorp gelabelde Docker-volume bewaard.
