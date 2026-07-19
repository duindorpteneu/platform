# Rollback

## Applicatierollback

Bij mislukte health- of routechecks probeert `scripts/deploy-vps.sh` de vorige `duindorpteneu-app:<PREVIOUS_REVISION>` terug te zetten en herstelt het vorige runtimebestand. De vorige image wordt behouden. Daarna moeten lokaal en publiek `/api/health`, `/`, `/admin` en `/uitgifte` opnieuw worden gecontroleerd.

Voor een handmatige redeploy start je `Deploy` via `workflow_dispatch`, kies je `redeploy` en geef je een volledige oudere SHA op die onderdeel is van `main`. Die SHA doorloopt opnieuw build, staging en productionapproval. Dit is de enige normale manier waarop production een oudere SHA accepteert.

## Database

Databasemigraties zijn forward-only en worden nooit automatisch teruggedraaid. Een approllback na een schemawijziging is alleen veilig wanneer de migrationset achterwaarts compatibel is. Bij twijfel: providerflags uit, productieapproval stoppen, herstelpunt veiligstellen en een additieve forward-fix maken. Een database-restore is een afzonderlijke, expliciet goedgekeurde productieactie en valt niet onder het deployscript.

`PREVIOUS_REVISION` is leeg bij een eerste deployment; dan bestaat geen automatische appfallback. Los de configuratie/imagefout op en voer staging opnieuw uit.
