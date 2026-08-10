# Rollback

## Applicatierollback

Bij mislukte health- of routechecks probeert `scripts/deploy-vps.sh` de vorige `duindorpteneu-app:<PREVIOUS_REVISION>` terug te zetten en herstelt het vorige runtimebestand. De vorige image wordt behouden. Daarna moeten lokaal en publiek `/api/health`, `/`, `/admin` en `/uitgifte` opnieuw worden gecontroleerd.

Voor de eerste overgang vanaf production-SHA `a79c8d8…` is uitsluitend de
aparte workflow `Adopt exact legacy production rollback target` toegestaan.
Zij archiveert niet opnieuw gebouwde code, maar de live manifestgebonden image,
en bewijst candidate→legacy→candidate op staging. Legacyhealth zonder
`artifactDigest` wordt alleen geaccepteerd wanneer signed capturebewijs,
adoptierun-ID, exacte legacy-SHA en productionmanifest alle overeenkomen. Er is
geen herbruikbare flag of algemene bypass. De oude image bevat geen scheduler:
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
