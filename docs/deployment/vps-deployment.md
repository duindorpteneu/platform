# VPS-deployment

De applicatie draait per environment als één Rootless-Docker-Composeproject met een app- en schedulercontainer. Caddy blijft buiten Docker en proxyt uitsluitend naar de app-loopbackbinding.

| Onderdeel | Staging | Production |
| --- | --- | --- |
| Publieke origin | `https://staging-duindorp.dgwebservices.nl` | `https://duindorp.dgwebservices.nl` |
| Routes | `/`, `/admin`, `/uitgifte` | `/`, `/admin`, `/uitgifte` |
| Hostbinding | `127.0.0.1:14000` | `127.0.0.1:24000` |
| Composeproject | `duindorpteneu-staging` | `duindorpteneu-production` |
| Runtimepad | `/srv/apps/duindorpteneu/staging` | `/srv/apps/duindorpteneu/production` |
| Runnerlabels | `self-hosted, linux, x64, duindorpteneu, staging` | `self-hosted, linux, x64, duindorpteneu, production` |

`deploy/compose.vps.yml` bevat precies één appservice en één scheduler, geen Caddy, geen aparte admin-/uitgifteservice, geen volumes en geen `build:`. Beide draaien zonder Linux-capabilities en met een read-only rootfilesystem. Alleen de app publiceert containerpoort 3000 op de vaste loopbackpoort; de scheduler gebruikt uitsluitend het Compose-interne netwerk.

## Health- en routematrix

| Controle | Staging | Production | Acceptatie |
| --- | --- | --- | --- |
| Lokale health | `http://127.0.0.1:14000/api/health` | `http://127.0.0.1:24000/api/health` | 200 JSON; exact environment en SHA |
| Publieke health | `https://staging-duindorp.dgwebservices.nl/api/health` | `https://duindorp.dgwebservices.nl/api/health` | Zelfde identiteit; geen secrets/DB-metadata |
| Ouderportaal | `/` | `/` | 200 login of geldige sessie naar `/mijn-tenue` |
| Backoffice | `/admin` | `/admin` | Zelfde-origin login/MFAredirect of 200 na autorisatie; nooit 404/loop |
| Uitgifte | `/uitgifte` | `/uitgifte` | Zelfde-origin login/MFAredirect of 200 na autorisatie; nooit 404/loop |

De checks proberen maximaal twintig keer met drie seconden interval en korte time-outs. HTTP 503 is verplicht wanneer kritieke runtimeconfiguratie of database-readiness ontbreekt.

## Releaseflow

Een push naar `main` start `.github/workflows/deploy.yml`: preflight/gates → imagebouw → stagingdeploy en route-/schedulerchecks. Production start nooit automatisch. De handmatige `.github/workflows/promote-production.yml` vereist het succesvolle staging-run-ID, de exacte SHA, tekstbevestiging en daarna de GitHub production-environmentapproval. `duindorpteneu-app:<SHA>` wordt één keer gebouwd; production downloadt dezelfde stagingartefacten en vergelijkt build-, staging- en lokaal geladen digest.

De expliciete `workflow_dispatch`-modus `redeploy` accepteert alleen een volledige SHA die voorouder van `origin/main` is. In normale modus moet de release-SHA exact de actuele `origin/main` zijn; een verouderde wachtende run stopt veilig.

## Eerste stagingdeploy

1. Vul de ontbrekende heartbeatsecret en acceptatievariabele uit `github-environments.md`.
2. Houd `MOLLIE_ENABLED=false` en `EMAIL_ENABLED=false`.
3. Controleer dat beide runners Rootless Docker en Compose v2 zien en eigenaar zijn van hun eigen runtimepad.
4. Merge de branch pas na review naar `main`; de push start uitsluitend de stagingflow.
5. Controleer staginghealth, scheduler, `/`, `/admin`, `/uitgifte`, core/Mollie/restore-evidence en start productionpromotie pas daarna afzonderlijk.

Het deployscript wijzigt Caddy, UFW, SSH, systemd of Docker-globalconfiguratie niet en gebruikt geen `sudo`.

## Runtime en troubleshooting

`.env.runtime`, `REVISION`, `PREVIOUS_REVISION` en `RELEASE_MANIFEST` worden atomisch met mode 0600 geschreven. Een per-environment `flock` voorkomt overlap. Preflight weigert een rootful Dockerdaemon, verkeerde host/poort/pad/projectnaam, `0.0.0.0`, fout Supabaseproject, onplausibele keys, verkeerde Molliemodus en ongeldige encryptiesleutel.

Bij falen: bekijk de geredigeerde joblogs, controleer `docker info`, `docker compose ... config`, de Caddy-upstream en `/api/health`. Het script ruimt alleen oude tags uit repository `duindorpteneu-app` op en raakt geen andere projecten.
