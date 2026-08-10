# Deploymentaudit — bijgewerkt 2026-08-11

## Bevindingen en acties

- De bestaande twee systemdworkflows bouwden staging en production afzonderlijk. De huidige flow gebruikt `Deploy staging` voor iedere main-SHA en een afzonderlijke handmatige `Promote production`; een wachtende productionapproval kan daardoor geen nieuwere stagingfix blokkeren.
- Dockerfile/Compose/image-digestpromotie zijn aanwezig. Compose heeft één gepubliceerde appservice en één niet-gepubliceerde scheduler; uitsluitend de app bindt op loopback.
- De build-time browser-Supabaseconfig maakte één image voor twee projecten onmogelijk. Publieke Supabaseconfig wordt nu server-side per request in de HTML-bootstrap geïnjecteerd; geheimen worden nooit geïnjecteerd. De CSP staat alleen Supabase HTTPS/WSS-hosts toe wanneer geen buildspecifieke origin aanwezig is.
- `/admin` bestond niet. Het is nu een staff-beveiligde alias naar de canonieke `/backoffice`; `/uitgifte` blijft dezelfde applicatieservice.
- `/` verwees ten onrechte naar de backoffice en ouder-OTP zette het e-mailadres in de querystring. `/` toont nu de ouderlogin (of hervat `/mijn-tenue`), terwijl de OTP-flow een versleutelde, HttpOnly en tien minuten geldige challengecookie gebruikt. Staffredirects komen uitsluitend van de canonical app-origin en vertrouwen geen Host-header.
- Health gaf geen release-identiteit. Het actuele antwoord bevat uitsluitend status, service, environment, revision en `artifactDigest`, met 503 bij ongeldige config/readiness.
- Staging `APP_HOST` bevatte een extra `d`; deze GitHub variable is gecorrigeerd. Andere variables waren correct en Supabaseprojecten verschillen.
- Staging bevat de Supabase-, server-action-, parent-, QR-, cron-, import-, Mollie-, SendGrid- en encrypted-cleanupsecretnamen. `OPERATIONS_HEARTBEAT_URL`, de dedicated SendGrid-adminkey/accountfingerprint en de IMAP-testinbox ontbreken nog. Production mist de nieuwe QR-/import-/heartbeat- en mail-v2-configuratie en blijft geblokkeerd.
- De organisatie gebruikt GitHub Free met een private repository. Production heeft alleen de `main` branch policy en geen required reviewer; de promotieverifier weigert daarom iedere productionmutatie totdat een planupgrade en onafhankelijke reviewer met geblokkeerde self-review aantoonbaar zijn.
- GitHub-native private-repositoryattestaties vereisen Enterprise Cloud. Het releaseartifact gebruikt daarom een keyless Sigstore/Cosign-bundel via GitHub OIDC; de ondertekende checksumset bindt image, manifest en SPDX-SBOM.
- Iedere handmatige stagingacceptatie gebruikt nu vóór environmentsecrets een secrets-vrije trusted-main-preflight en production houdt dezelfde stagingconcurrency vast.
- Alle vier self-hosted mutatiejobs eisen afzonderlijke runnernamen, Unix-users, homes, Rootless-Docker-sockets met mode `0600`, data-roots en private runtimebomen. De bestaande gedeelde `deploy`-principal voldoet niet meer en blokkeert bewust tot hostbeheer de runners opnieuw provisiont.
- De actuele productionrelease `a79c8d8…` heeft nog legacyhealth zonder `artifactDigest`, een historisch gequote runtimebestand en geen huidige schedulerentrypoint; de oorspronkelijke artifacts zijn verlopen. Een afzonderlijke eenmalige, signed adoptieworkflow bindt de werkelijk draaiende image read-only, normaliseert runtime zonder `eval`, bewijst op staging candidate→legacy-app met gestopte scheduler→candidate met gezonde scheduler en bindt dat bewijs aan rollback/promotie. Rebuild, hergebruik na een geslaagde adoptie of een algemene healthbypass bestaat niet.
- De vier staging-specifieke Mollie-acceptatie-RPC's en hun ledgertabel zijn forward-only uit het productschema verwijderd. De externe acceptance-run vereist exact staging/TLS, deelt de stagingdeploy-serialisatiegroep, wijzigt geen globale instellingen en de deploy blokkeert vóór activatie wanneer een verboden RPC niet exact `404/PGRST202` retourneert.
- De merge van PR `#49` slaagde, maar deployrun `31434321788` stopte veilig vóór stagingactivatie omdat de volledige Debian 12 Node-runtime de 0-HIGH/0-CRITICAL-gate niet haalde. De runtime is vervangen door digest-gepinde distroless Node 22 op Debian 13 als numeric non-root, zonder shell of package manager. App en scheduler delen hetzelfde image; Compose gebruikt absolute Node-healthchecks en Sharp/libvips wordt expliciet meegeleverd. Het volledige lokale kandidaatimage is met dezelfde Trivy 0.70.0-versie op 0 HIGH/0 CRITICAL en met echte app-, scheduler- en Sharp-smokes bewezen. De hosted scan/deploy op de herstelmerge-SHA blijft verplicht.

## Resterende externe validatie

Production is bewust niet uitgevoerd. Voor NO-GO naar GO zijn nog nodig: de
afgeschermde core/Mollie/SendGrid/restore/operationsruns op één nieuwe
merge-SHA, de encrypted cleanup-backup/apply, een echte heartbeat-/alarmtest,
SendGrid Mail Send zonder 401 plus inbox/eventbewijs, required-reviewerbeleid
na planupgrade en bewijs dat Duindorp staging, Duindorp production en Castivo
afzonderlijke Linux-users/rootless sockets/runners gebruiken.
