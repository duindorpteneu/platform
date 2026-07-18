# VPS-deployment met GitHub self-hosted runners

Status: implementatiecontract; VPS-bootstrap nog uit te voeren

Deze route is bedoeld voor een VPS waarop ook Castivo draait. Duindorp gebruikt uitsluitend eigen Linux-gebruikers, runnerlabels, systemd-services, mappen en loopbackpoorten. Castivo-services, containers, poorten, bestanden en runners worden niet gewijzigd.

## 1. Beveiligingsmodel zonder GitHub-upgrade

De private repository draait voorlopig op GitHub Free. GitHub Environments en Environment Secrets zijn daardoor niet beschikbaar. De workflows gebruiken daarom repository-level Actions secrets en variables met een harde prefix `STAGING_` of `PRODUCTION_`.

Dit is een tijdelijke beperking, geen gelijkwaardige vervanging voor protected environments. Iedereen die workflowcode op `main` kan wijzigen, kan technisch een job naar een self-hosted runner sturen. Beperk repository-write strikt, laat nooit pull-requestcode op de deployrunners draaien en upgrade later naar protected environments. GitHub waarschuwt dat persistente self-hosted runners door workflowcode blijvend gecompromitteerd kunnen raken.

De aanvullende waarborgen zijn:

- CI blijft op geïsoleerde GitHub-hosted runners;
- alleen geslaagde `main`-CI activeert staging;
- staging en production hebben verschillende repo-level runners en Linux-gebruikers;
- production start uitsluitend handmatig vanaf een gepubliceerde release-tag;
- de productionuitvoerder moet verschillen van de GitHub Release-publiceerder;
- dezelfde commit moet groene CI én een geslaagde stagingdeploy hebben;
- productionsecrets worden pas in de deployjob geïnjecteerd nadat de autorisatiejob groen is;
- workflows schrijven nooit secretwaarden naar logs.

## 2. Vaste isolatie op de VPS

| Onderdeel | Staging | Production |
| --- | --- | --- |
| Runnerlabel | `duindorp-staging` | `duindorp-production` |
| Linux-gebruiker | `duindorp-staging` | `duindorp-production` |
| Releasepad | `/srv/duindorp-tenueportaal/staging` | `/srv/duindorp-tenueportaal/production` |
| systemd-service | `duindorp-tenueportaal-staging.service` | `duindorp-tenueportaal-production.service` |
| Voorgestelde loopbackpoort | `32110` | `32120` |
| Supabase | Eigen stagingproject | Ander productionproject |

Controleer eerst met `ss -ltnp` dat de gekozen poorten op de nieuwe VPS vrij zijn. Beide Node-processen binden uitsluitend aan `127.0.0.1`; alleen Caddy luistert publiek op 80/443.

## 3. GitHub repository variables

Maak iedere variable via **Settings → Secrets and variables → Actions → Variables** of met `gh variable set NAME --body VALUE --repo duindorpteneu/platform`.

| Naam per prefix | Voorbeeld staging | Betekenis |
| --- | --- | --- |
| `<PREFIX>_APP_PORT` | `32110` | Vrije loopbackpoort op de VPS |
| `<PREFIX>_APP_BASE_URL` | `https://staging-tenue.example.nl` | Exacte publieke HTTPS-origin |
| `<PREFIX>_NEXT_PUBLIC_SUPABASE_URL` | `https://PROJECT.supabase.co` | URL van uitsluitend het omgevingsproject |
| `<PREFIX>_NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_...` | Publieke projectkey |
| `<PREFIX>_SUPABASE_PROJECT_ID` | Supabase project-ref | Twintig tekens uit het dashboard |
| `<PREFIX>_MOLLIE_ENABLED` | `false` | Harde providergrens; eerst uit |
| `<PREFIX>_EMAIL_ENABLED` | `false` | Harde providergrens; eerst uit |
| `<PREFIX>_SENDGRID_FROM_EMAIL` | Leeg tot configuratie gereed is | Geverifieerde afzender |
| `<PREFIX>_SENDGRID_REPLY_TO_EMAIL` | Leeg tot configuratie gereed is | Operationeel antwoordadres |
| `<PREFIX>_SENDGRID_PARENT_OTP_TEMPLATE_ID` | Leeg tot configuratie gereed is | SendGrid dynamic-template-ID |
| `<PREFIX>_SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY` | Leeg tot webhook gereed is | PEM met letterlijke `\n`, of DER als base64 |

Maak alle namen tweemaal met `<PREFIX>` gelijk aan `STAGING` en `PRODUCTION`. Staging en production gebruiken nooit dezelfde Supabase-URL, project-ref of publishable key.

## 4. GitHub repository secrets

Voer elk commando interactief uit; plak de waarde uitsluitend in de afgeschermde prompt. Gebruik geen `--body` op de commandline en plaats waarden niet in shellhistory.

```bash
gh secret set STAGING_SUPABASE_ACCESS_TOKEN --repo duindorpteneu/platform
gh secret set STAGING_SUPABASE_DB_PASSWORD --repo duindorpteneu/platform
gh secret set STAGING_SUPABASE_SECRET_KEY --repo duindorpteneu/platform
gh secret set STAGING_PARENT_TOKEN_PEPPER --repo duindorpteneu/platform
gh secret set STAGING_CRON_SECRET --repo duindorpteneu/platform
gh secret set STAGING_MOLLIE_API_KEY --repo duindorpteneu/platform
gh secret set STAGING_SENDGRID_API_KEY --repo duindorpteneu/platform

gh secret set PRODUCTION_SUPABASE_ACCESS_TOKEN --repo duindorpteneu/platform
gh secret set PRODUCTION_SUPABASE_DB_PASSWORD --repo duindorpteneu/platform
gh secret set PRODUCTION_SUPABASE_SECRET_KEY --repo duindorpteneu/platform
gh secret set PRODUCTION_PARENT_TOKEN_PEPPER --repo duindorpteneu/platform
gh secret set PRODUCTION_CRON_SECRET --repo duindorpteneu/platform
gh secret set PRODUCTION_MOLLIE_API_KEY --repo duindorpteneu/platform
gh secret set PRODUCTION_SENDGRID_API_KEY --repo duindorpteneu/platform
```

Eisen:

- `PARENT_TOKEN_PEPPER`: uniek per omgeving, cryptografisch willekeurig, minimaal 32 tekens;
- `CRON_SECRET`: uniek per omgeving, cryptografisch willekeurig, minimaal 16 tekens;
- staging Mollie: uitsluitend `test_...`;
- production Mollie: `live_...` is alleen toegestaan wanneer de productiongate akkoord is;
- providerkeys mogen ontbreken zolang hun `*_ENABLED`-variable `false` is;
- `SUPABASE_ACCESS_TOKEN` en databasewachtwoord worden alleen door de CLI-migratiestap gebruikt en niet naar `app.env` geschreven.

Controleer uitsluitend de namen, nooit de waarden:

```bash
gh secret list --repo duindorpteneu/platform
gh variable list --repo duindorpteneu/platform
```

## 5. VPS-bootstrap

De VPS heeft nodig:

- Ubuntu met securityupdates;
- Node.js 22 als `/usr/bin/node`;
- Caddy als systemd-service;
- uitgaand HTTPS naar GitHub, Supabase, Mollie en SendGrid;
- inkomend 80/443; geen publieke app- of databasepoorten;
- DNS A/AAAA voor beide hostnamen naar de VPS;
- voldoende schijfruimte voor vijf releases per omgeving.

Maak twee niet-gedeelde gebruikers en paden. Voeg deze gebruikers niet toe aan de Dockergroep van Castivo.

```bash
sudo useradd --create-home --user-group --shell /bin/bash duindorp-staging
sudo useradd --create-home --user-group --shell /bin/bash duindorp-production
sudo install -d -o duindorp-staging -g duindorp-staging -m 0700 /srv/duindorp-tenueportaal/staging/{releases,shared}
sudo install -d -o duindorp-production -g duindorp-production -m 0700 /srv/duindorp-tenueportaal/production/{releases,shared}
```

Installeer de twee templates uit `deploy/systemd/` onder `/etc/systemd/system/`. Geef elke runner via een afzonderlijk sudoers-bestand uitsluitend toestemming zijn eigen service te herstarten:

```text
duindorp-staging ALL=(root) NOPASSWD: /usr/bin/systemctl restart duindorp-tenueportaal-staging.service
duindorp-production ALL=(root) NOPASSWD: /usr/bin/systemctl restart duindorp-tenueportaal-production.service
```

Valideer sudoers altijd met `visudo -cf <bestand>`. De runners krijgen geen algemene sudo-, Docker- of Caddyrechten.

Registreer twee repository-level Actions-runners volgens de actuele GitHub-instructies. Gebruik aparte installatiemappen en services:

- staginglabels: `duindorp-staging` plus de automatische labels `self-hosted,linux,x64`;
- productionlabels: `duindorp-production` plus de automatische labels;
- scope: uitsluitend `duindorpteneu/platform`;
- services draaien als hun gelijknamige Linux-gebruiker.

## 6. Caddy naast Castivo

Beheer Caddy modulair. Laat de bestaande Castivo-snippet intact en voeg in de globale Caddyfile hoogstens één import toe:

```caddyfile
import /etc/caddy/sites/*.caddy
```

Kopieer `deploy/caddy/duindorp-tenueportaal.caddy.example` naar een eigen bestand onder `/etc/caddy/sites/`, vervang de twee voorbeeldhostnamen en pas poorten alleen aan wanneer de GitHub-variables hetzelfde worden aangepast.

Voer vóór reload uit:

```bash
sudo caddy fmt --overwrite /etc/caddy/sites/duindorp-tenueportaal.caddy
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy verzorgt automatische HTTPS en proxyt naar de twee loopbackservices. Het deployscript wijzigt of herlaadt Caddy niet.

## 7. Deploygedrag

Staging:

1. `CI` slaagt op een push naar `main`;
2. `Deploy staging` checkt exact die SHA uit;
3. alle variables/secrets worden fail-closed gevalideerd;
4. de standalone Next.js-release wordt gebouwd;
5. `supabase db push --dry-run` controleert de remote migraties;
6. forward-only migraties worden toegepast;
7. `app.env` wordt atomair met mode `0600` geschreven;
8. de `current`-symlink schakelt atomair om en systemd herstart;
9. lokale én publieke health moeten groen zijn;
10. maximaal vijf appreleases blijven bewaard.

Production:

1. persoon A publiceert een niet-prerelease GitHub Release `vX.Y.Z`;
2. persoon B start `Deploy production` handmatig en typt `DEPLOY PRODUCTION`;
3. de autorisatiejob bewijst main, groene CI, groene staging op dezelfde SHA en verschillende actoren;
4. pas daarna start de productionrunner met productiesecrets;
5. migratie, atomische appdeploy en health verlopen gelijk aan staging.

Bij een mislukte apphealth wordt de vorige appsymlink teruggezet. Toegepaste databasemigraties worden nooit teruggedraaid; een schemafout vereist een additieve forward-fix volgens het operationsrunbook.

## 8. Eerste ingebruikname

- Houd `MOLLIE_ENABLED=false` en `EMAIL_ENABLED=false` tijdens de eerste stagingdeploy.
- Controleer `/api/health`, medewerker-TOTP, ouder-OTP met provider uit en alle drie werkvlakken.
- Activeer en test SendGrid en Mollie afzonderlijk volgens [STAGING_VERIFICATION.md](STAGING_VERIFICATION.md).
- Richt de e-mailworker, retentiejob, interne healthmonitor en back-up/restore-oefening in vóór production.
- Start production pas nadat [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) volledig is ondertekend.
