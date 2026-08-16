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

`Deploy staging` bouwt en bewaart het immutable image-artifact plus manifest,
SBOM, signed checksums en deployattestation. `Promote production` vereist de
exacte 40-teken SHA, menselijke bevestiging en acht afzonderlijke run-ID's:
deploy, core, volledige Phase B, Mollie, SendGrid, restore, applicatierollback
en operations. Iedere run moet op dezelfde SHA/digest groen, uniek, niet
verlopen en maximaal 48 uur oud zijn; acceptatieruns moeten ná de stagingdeploy
zijn gestart.

Na de technisch afgedwongen onafhankelijke environmentapproval verifieert de
productionrunner alles opnieuw. Vóór migratie wordt een encrypted logical
recovery point gemaakt, netwerkloos hersteld, geüpload, weer uit Actions
teruggedownload en bytegelijk aan het evidence-checksum bewezen. Een nieuwere
`main`-SHA of ontbrekend required-reviewerbeleid blokkeert.

Alleen bij de eerste overgang wordt bovendien het run-ID van de signed
legacy-adoptie opgegeven. De eenmalige capture en adoptiresultaten blijven
gebonden aan de oorspronkelijke adoptierun; zij worden niet opnieuw gemaakt
of stil aan een latere kandidaat gekoppeld. De actuele rollbackdrill bewijst
afzonderlijk kandidaat → exact gecapturede legacyrelease → kandidaat. De
promotie verifieert daarbij zowel de signed legacyprovenance als de actuele
kandidaatgebonden rollbackattestatie. De eenmalige provenance valt niet onder
het 48-uursvenster voor actuele acceptatieruns, maar het signed artifact moet
wel bestaan en niet verlopen zijn. Na de eerste productiepromotie moet het
legacy-inputveld leeg blijven.
Tijdens die exacte legacyrollback draait bewust alleen de historische app:
die image bevatte nog geen schedulerbestand. Providerflags staan uit en de
scheduler is aantoonbaar gestopt. Terugkeer naar de kandidaat start en bewijst
de huidige scheduler opnieuw; dit tijdelijke app-only-contract is geen
uitzondering voor latere releases.

## VPS-boundary

Composeprojectnamen en poorten voorkomen operationele conflicten, maar vervangen geen hostisolatie. Voor production is vereist:

- aparte Linux-users en Rootless-Docker-sockets voor Duindorp staging en production;
- afzonderlijke runnerregistraties met uitsluitend de eigen environmentlabels;
- Castivo onder een andere user/socket/runtimeboom;
- geen gedeelde secrets, volumes of Caddy-snippets;
- restore-drills op een tijdelijke GitHub-hosted runner, niet in een siblingproject op de VPS.

Canonieke identities zijn `duindorp-staging-01` onder
`duindorp-staging` en `duindorp-production-01` onder
`duindorp-production`, met private homes, verschillende UID/GID's,
Rootless-sockets en Docker data-roots. De oude gedeelde `deploy`-principal is
niet meer toegestaan. Iedere Rootless-Docker-socket heeft mode `0600`.
