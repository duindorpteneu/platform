# Production operations

Production gebruikt geen GitHub-cron voor de minuut-SLA. De immutable applicatie-image start binnen het eigen Composeproject twee geharde services:

- `app`: uitsluitend op `127.0.0.1:24000`, achter de bestaande Caddy-site;
- `scheduler`: geen hostpoort of volume; roept iedere minuut de interne e-mailworker en health aan en voert retentie bij start plus uiterlijk iedere vijf minuten uit. Een falende e-mailrun verhindert de afzonderlijke retentiepoging niet.

De scheduler gebruikt alleen het omgevingsspecifieke runtimebestand, communiceert via `http://app:3000` en logt nooit bearer- of heartbeat-URL's. Een onverwacht gepauzeerde actieve mailworker maakt de scheduler ongezond. Operationele degradatie stopt de externe heartbeat, maar veroorzaakt geen app-restartloop.

## Externe bewaking

`OPERATIONS_HEARTBEAT_URL` is een unieke geheime HTTPS dead-man-switch-URL. Productionruntime weigert zonder deze waarde te deployen. Configureer de externe monitor op maximaal drie minuten zonder geldige ping en laat die buiten deze VPS alarmeren naar de operationeel eigenaar.

Bewijs vóór productie:

1. één gezonde ping per minuut terwijl e-mail conform beide switches actief of bewust gepauzeerd is;
2. alarm na het gecontroleerd blokkeren van de heartbeat, zonder secret in logs;
3. herstelmelding nadat de scheduler weer gezond is;
4. interne health geeft 503 bij twee gemiste actieve worker-runs, achterstallige of mislukte retentie, verlopen importstaging, onzekere/failed mail, recente bounce/drop/failure of betaal-/webhookreconciliatie;
5. Caddy, Castivo en andere Composeprojecten zijn niet gewijzigd.

## Releasepromotie

`Deploy staging` bouwt en bewaart het immutable image-artefact plus het geverifieerde stagingmanifest. Production wordt uitsluitend handmatig gestart via `Promote production` met:

- het succesvolle staging-run-ID;
- de exacte 40-teken release-SHA;
- bevestiging `PROMOTE-PRODUCTION`;
- daarna de bestaande GitHub production-environmentapproval.

De promotieworkflow verifieert runconclusie, workflowpad, SHA en main-afstamming, downloadt beide artefacten uit die stagingrun en laat `deploy-vps.sh` de drie digests opnieuw vergelijken. Een nieuwere main-SHA maakt een oude gewone promotie ongeldig.

## VPS-boundary

Composeprojectnamen en poorten voorkomen operationele conflicten, maar vervangen geen hostisolatie. Voor production is vereist:

- aparte Linux-users en Rootless-Docker-sockets voor Duindorp staging en production;
- afzonderlijke runnerregistraties met uitsluitend de eigen environmentlabels;
- Castivo onder een andere user/socket/runtimeboom;
- geen gedeelde secrets, volumes of Caddy-snippets;
- restore-drills op een tijdelijke GitHub-hosted runner, niet in een siblingproject op de VPS.
