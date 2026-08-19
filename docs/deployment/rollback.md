# Rollback

## Applicatierollback

Vóór het laden van een kandidaat valideert `scripts/deploy-vps.sh` het manifest en
de OCI-/configdigest van de actieve vorige image. Het script geeft die image
vervolgens een unieke, omgevingsgebonden `rollback-<omgeving>-<SHA>-<run>-<poging>`-
alias. Bij mislukte health- of routechecks gebruikt iedere automatische
herstelactie uitsluitend deze alias en herstelt zij het vorige runtimebestand.
Daardoor blijft de rollbackimage ook bij een redeploy van exact dezelfde SHA
ongewijzigd wanneer `docker load` de gewone SHA-tag naar de kandidaat verplaatst.
Oudere aliases van dezelfde omgeving worden pas na volledige acceptatie
opgeruimd; de onmiddellijk vorige rollbacktarget blijft behouden. Daarna moeten
lokaal en publiek `/api/health`, `/`, `/admin` en `/uitgifte` opnieuw worden
gecontroleerd.

Voor de eerste overgang vanaf production-SHA `a79c8d8…` is uitsluitend de
aparte workflow `Adopt exact legacy production rollback target` toegestaan.
Zij archiveert niet opnieuw gebouwde code, maar de manifestgebonden lokale image,
en bewijst candidate→legacy→candidate op staging. Legacyhealth zonder
`artifactDigest` wordt alleen geaccepteerd wanneer signed capturebewijs,
adoptierun-ID, exacte legacy-SHA en productionmanifest alle overeenkomen. De
eenmalige adoptieprovenance blijft aan haar oorspronkelijke workflowrun
gebonden; iedere latere releasecandidate moet zelf de volledige
candidate→legacy→candidate-drill doorlopen. Er is geen herbruikbare flag of
algemene bypass. Bij exact nul zichtbare
productionappcontainers wordt de eenmalige provenance-uitzondering expliciet in
het signed bewijs vastgelegd; publieke én loopbackhealth, alle OCI/config/layer-
digests en bytegelijke before/after-state zijn dan verplicht. Dit is geen claim
dat de lokale tag rechtstreeks aan een zichtbare live container was gebonden.
De oude image bevat geen scheduler:
tijdens uitsluitend deze legacyfase zijn alle providers uit, is de scheduler
aantoonbaar gestopt en draait alleen de app. Het kandidaat-herstel moet app én
scheduler weer gezond bewijzen. Het historische gequote runtimebestand wordt
vóór gebruik zonder `eval` naar het huidige raw-envcontract genormaliseerd. Zie
[vps-deployment.md](vps-deployment.md#eenmalige-legacy-overgang).

Een geplande terugkeer naar oudere applicatielogica gebeurt als een beoordeelde
revert-/forward-fixcommit op `main`. Die nieuwe commit doorloopt opnieuw de
volledige CI-, build-, stagingacceptatie- en productionapprovalketen. De
deployworkflow accepteert geen losse oudere SHA; zo kan een oud artifact niet
de actuele bron- en acceptatiebinding omzeilen.

## Database

Databasemigraties zijn forward-only en worden nooit automatisch teruggedraaid. Een approllback na een schemawijziging is alleen veilig wanneer de migrationset achterwaarts compatibel is. Bij twijfel: providerflags uit, productieapproval stoppen, herstelpunt veiligstellen en een additieve forward-fix maken. Een database-restore is een afzonderlijke, expliciet goedgekeurde productieactie en valt niet onder het deployscript.

`PREVIOUS_REVISION` is leeg bij een eerste deployment; dan bestaat geen automatische appfallback. Los de configuratie/imagefout op en voer staging opnieuw uit.
