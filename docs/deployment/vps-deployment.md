# VPS-deployment

De applicatie draait per environment als één Rootless-Docker-Composeproject met een app- en schedulercontainer. Caddy blijft buiten Docker en proxyt uitsluitend naar de app-loopbackbinding.

| Onderdeel | Staging | Production |
| --- | --- | --- |
| Publieke origin | `https://staging-duindorp.dgwebservices.nl` | `https://duindorp.dgwebservices.nl` |
| Routes | `/`, `/admin`, `/uitgifte` | `/`, `/admin`, `/uitgifte` |
| Hostbinding | `127.0.0.1:14000` | `127.0.0.1:24000` |
| Composeproject | `duindorpteneu-staging` | `duindorpteneu-production` |
| Runtimepad | `/srv/apps/duindorpteneu/staging` | `/srv/apps/duindorpteneu/production` |
| Runnerlabels | `self-hosted, linux, x64, duindorpteneu, staging, deploy` | `self-hosted, linux, x64, duindorpteneu, production, deploy` |
| Runner / Unix-user | `duindorp-staging-01` / `duindorp-staging` | `duindorp-production-01` / `duindorp-production` |
| Private home | `/home/duindorp-staging` | `/home/duindorp-production` |

`deploy/compose.vps.yml` bevat precies één appservice en één scheduler, geen Caddy, geen aparte admin-/uitgifteservice, geen volumes en geen `build:`. Beide draaien zonder Linux-capabilities en met een read-only rootfilesystem. Alleen de app publiceert containerpoort 3000 op de vaste loopbackpoort; de scheduler gebruikt uitsluitend het Compose-interne netwerk.

## Health- en routematrix

| Controle | Staging | Production | Acceptatie |
| --- | --- | --- | --- |
| Lokale health | `http://127.0.0.1:14000/api/health` | `http://127.0.0.1:24000/api/health` | 200 JSON; exact environment, SHA en artifactdigest |
| Publieke health | `https://staging-duindorp.dgwebservices.nl/api/health` | `https://duindorp.dgwebservices.nl/api/health` | Dezelfde drieledige identiteit; geen secrets/DB-metadata |
| Ouderportaal | `/` | `/` | 200 login of geldige sessie naar `/mijn-tenue` |
| Backoffice | `/admin` | `/admin` | Zelfde-origin login/MFAredirect of 200 na autorisatie; nooit 404/loop |
| Uitgifte | `/uitgifte` | `/uitgifte` | Zelfde-origin login/MFAredirect of 200 na autorisatie; nooit 404/loop |

De checks proberen maximaal twintig keer met drie seconden interval en korte time-outs. HTTP 503 is verplicht wanneer kritieke runtimeconfiguratie of database-readiness ontbreekt.

## Releaseflow

Een push naar `main` start `.github/workflows/deploy.yml`, maar deployment
wacht eerst op de canonieke groene `push`-CI-run met beide benoemde jobs op
exact dezelfde SHA. Daarna wordt `duindorpteneu-app:<SHA>` één keer gebouwd,
op high/critical runtimekwetsbaarheden gescand, als SPDX-SBOM beschreven en
met een keyless Sigstore/Cosign-bundel via GitHub OIDC ondertekend. De
ondertekende `SHA256SUMS` bindt image, releasemanifest en SPDX-SBOM. Staging
verifieert ondertekenaar, OIDC-issuer en alle checksums vóór migratie en
appactivatie.

Production start nooit automatisch. De handmatige
`.github/workflows/promote-production.yml` vereist run-ID's en
artifactgebonden attestaties voor stagingdeploy, core, Phase B, Mollie,
SendGrid, restore, applicatierollback en operations, plus
`HUMAN-UAT-PASSED` en
`PROMOTE-PRODUCTION`. Alle remote run-/job-/artifactmetadata, checksums,
provenance, actuele `main` en live staging-SHA worden vóór én na de
production-environmentapproval gecontroleerd. Production downloadt exact het
stagingartifact en bouwt niets opnieuw.

De release-SHA moet altijd exact de actuele `origin/main` zijn; een verouderde
wachtende run stopt veilig. Terugkeer naar oudere logica gebeurt via een nieuwe
revert-/forward-fixcommit, niet via een oudere-SHA-redeploy.

## Eerste stagingdeploy

1. Vul de ontbrekende heartbeatsecret en acceptatievariabele uit `github-environments.md`.
2. Houd `MOLLIE_ENABLED=false` en `EMAIL_ENABLED=false`.
3. Controleer dat beide runners Rootless Docker en Compose v2 zien en eigenaar zijn van hun eigen runtimepad.
4. Merge de branch pas na review naar `main`; de push start uitsluitend de stagingflow.
5. Controleer staginghealth, scheduler, `/`, `/admin`, `/uitgifte` en de
   artifactgebonden core/Mollie/SendGrid/restore/operationsbewijzen. Menselijke
   UAT volgt daarna; productionpromotie is een afzonderlijk changebesluit.

Het deployscript wijzigt Caddy, UFW, SSH, systemd of Docker-globalconfiguratie niet en gebruikt geen `sudo`.

De runnerboundary is fail-closed: `/srv/apps/duindorpteneu` is root-owned en
niet schrijfbaar, iedere environmentruntime is vooraf aangelegd met mode 0700,
de peerhome en -runtime zijn ontoegankelijk, de Rootless-socket en Docker
data-root horen bij de eigen principal en een root-owned provisioningmarker
bindt runnernaam, user, home en runtime. De repository maakt deze hostobjecten
niet zelf aan. De socket is uitsluitend voor de canonical principal lees- en
schrijfbaar (mode `0600`).

## Eenmalige legacy-overgang

De huidige productie-SHA `a79c8d8…` publiceert nog geen `artifactDigest`; de
historische Actions-artifacts zijn verlopen. Vóór de eerste gewone promotie
moet daarom exact eenmaal `Adopt exact legacy production rollback target`
draaien, na de kandidaatdeploy en vóór de rollbackdrill. Die workflow:

1. verifieert historische run `29754524344`, het gelockte productionmanifest,
   lokale image, alle OCI/config/layerdigests en publieke plus loopbackhealth vóór
   en na een read-only `docker save`;
2. ondertekent manifest, capturebewijs en recovered archive via Cosign/OIDC;
3. normaliseert het historische gequote runtimecontract zonder `eval`, forceert
   e-mail, Mollie en dynamische import uit en bewijst op staging kandidaat →
   exact manifestgebonden legacy-app → kandidaat;
4. installeert het geverifieerde legacydoel als vorige stagingrelease;
5. levert een signed adoption-run-ID/hash die de rollbackdrill en eerste
   promotie verplicht valideren.

Een zichtbare productioncontainer wordt direct aan het image gebonden. Als de
geïsoleerde productionrunner exact nul appcontainers ziet, is uitsluitend voor
deze SHA een expliciet geaudite fallback toegestaan: dezelfde lokale tag moet
bytegelijk aan manifest/config/layers zijn, de server op `127.0.0.1:24000` én
de publieke host moeten vóór/na exact dezelfde legacyhealth tonen en de volledige
runner-/manifest-/imagestate moet bytegelijk blijven. Het bewijs noemt dit
eerlijk `one-time-local-manifest-provenance-exception-v1`; het claimt dan geen
live-containerbinding en bouwt, haalt, laadt of start niets.

De workflow is automatisch onbruikbaar zodra production niet meer exact op
`a79c8d8…` draait of zodra een eerdere adoptierun succesvol was. De legacyimage
bevat geen schedulerbestand; tijdens de legacycheck wordt de scheduler daarom
aantoonbaar gestopt en alleen de app gestart. Na herstel moeten kandidaat-app
en -scheduler beide gezond zijn. Normale releases blijven altijd het huidige
artifactdigestcontract gebruiken.

## Runtime en troubleshooting

`.env.runtime`, `REVISION`, `PREVIOUS_REVISION` en `RELEASE_MANIFEST` worden atomisch met mode 0600 geschreven. Een per-environment `flock` voorkomt overlap. Preflight weigert een rootful Dockerdaemon, verkeerde host/poort/pad/projectnaam, `0.0.0.0`, fout Supabaseproject, onplausibele keys, verkeerde Molliemodus en ongeldige encryptiesleutel.

Bij falen: bekijk de geredigeerde joblogs, controleer `docker info`, `docker compose ... config`, de Caddy-upstream en `/api/health`. Het script ruimt alleen oude tags uit repository `duindorpteneu-app` op en raakt geen andere projecten.
