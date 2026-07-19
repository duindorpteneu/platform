# Deploymentaudit 2026-07-19

## Bevindingen en acties

- De bestaande twee systemdworkflows bouwden staging en production afzonderlijk en gebruikten verkeerde runnerlabels en geen GitHub environments. Ze zijn geconsolideerd naar één `deploy.yml` met minimale permissions, één concurrencygroep, vaste `needs` en environment-gates.
- Dockerfile/Compose/image-digestpromotie ontbraken. Deze zijn toegevoegd; Compose heeft één service en uitsluitend loopbackbindingen.
- De build-time browser-Supabaseconfig maakte één image voor twee projecten onmogelijk. Publieke Supabaseconfig wordt nu server-side per request in de HTML-bootstrap geïnjecteerd; geheimen worden nooit geïnjecteerd. De CSP staat alleen Supabase HTTPS/WSS-hosts toe wanneer geen buildspecifieke origin aanwezig is.
- `/admin` bestond niet. Het is nu een staff-beveiligde alias naar de canonieke `/backoffice`; `/uitgifte` blijft dezelfde applicatieservice.
- `/` verwees ten onrechte naar de backoffice en ouder-OTP zette het e-mailadres in de querystring. `/` toont nu de ouderlogin (of hervat `/mijn-tenue`), terwijl de OTP-flow een versleutelde, HttpOnly en tien minuten geldige challengecookie gebruikt. Staffredirects komen uitsluitend van de canonical app-origin en vertrouwen geen Host-header.
- Health gaf geen release-identiteit. Het antwoord bevat nu uitsluitend status, service, environment en revision, met 503 bij ongeldige config/readiness.
- Staging `APP_HOST` bevatte een extra `d`; deze GitHub variable is gecorrigeerd. Andere variables waren correct en Supabaseprojecten verschillen.
- Alle vier minimaal verwachte environmentsecrets zijn aanwezig. `PARENT_TOKEN_PEPPER` en `CRON_SECRET` ontbreken in beide environments en blokkeren een echte deploy. Providersecrets/variables zijn alleen nodig bij activering.
- Production heeft nog geen GitHub required-reviewerregel. De productionjob gebruikt wel het environment, maar de vereiste handmatige approval ontstaat pas na configuratie van required reviewers en prevent-self-review in GitHub.

## Resterende externe validatie

Een volledige main → staging → approval → productionrun is niet uitgevoerd: de branch is bewust niet gepusht/merged, twee verplichte secrets ontbreken en productionapproval is nog niet ingericht. Caddy/VPS/runnerconfiguratie is volgens opdracht reeds ingericht en wordt door deze repositorywijziging niet gemuteerd. De eerste echte run moet tevens bevestigen dat de runners een Rootless Dockerdaemon en schrijfrecht op uitsluitend hun eigen runtimepad hebben.
