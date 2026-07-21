# Deploymentaudit — bijgewerkt 2026-07-21

## Bevindingen en acties

- De bestaande twee systemdworkflows bouwden staging en production afzonderlijk. De huidige flow gebruikt `Deploy staging` voor iedere main-SHA en een afzonderlijke handmatige `Promote production`; een wachtende productionapproval kan daardoor geen nieuwere stagingfix blokkeren.
- Dockerfile/Compose/image-digestpromotie zijn aanwezig. Compose heeft één gepubliceerde appservice en één niet-gepubliceerde scheduler; uitsluitend de app bindt op loopback.
- De build-time browser-Supabaseconfig maakte één image voor twee projecten onmogelijk. Publieke Supabaseconfig wordt nu server-side per request in de HTML-bootstrap geïnjecteerd; geheimen worden nooit geïnjecteerd. De CSP staat alleen Supabase HTTPS/WSS-hosts toe wanneer geen buildspecifieke origin aanwezig is.
- `/admin` bestond niet. Het is nu een staff-beveiligde alias naar de canonieke `/backoffice`; `/uitgifte` blijft dezelfde applicatieservice.
- `/` verwees ten onrechte naar de backoffice en ouder-OTP zette het e-mailadres in de querystring. `/` toont nu de ouderlogin (of hervat `/mijn-tenue`), terwijl de OTP-flow een versleutelde, HttpOnly en tien minuten geldige challengecookie gebruikt. Staffredirects komen uitsluitend van de canonical app-origin en vertrouwen geen Host-header.
- Health gaf geen release-identiteit. Het antwoord bevat nu uitsluitend status, service, environment en revision, met 503 bij ongeldige config/readiness.
- Staging `APP_HOST` bevatte een extra `d`; deze GitHub variable is gecorrigeerd. Andere variables waren correct en Supabaseprojecten verschillen.
- Alle bestaande runtime-/providersecret-namen, inclusief `PARENT_TOKEN_PEPPER` en `CRON_SECRET`, zijn aanwezig. Nieuw ontbreekt `OPERATIONS_HEARTBEAT_URL`; productionpreflight blokkeert bewust totdat een onafhankelijke monitor is gekozen. Voor de Mollie-acceptatie ontbreekt de niet-geheime stagingvariable `MOLLIE_PROFILE_ID`.
- Production vereist review door `TIXOCEO`. Er is geen productionapproval verleend; superseded wachtende runs zijn na succesvolle stagingdeploy geannuleerd.

## Resterende externe validatie

Staging is meermaals via het immutable pad gedeployed; de actuele mobiele release `965233d…` is publiek groen. Production is bewust niet uitgevoerd. Voor NO-GO naar GO zijn nog nodig: de afgeschermde core/Mollie/restore-runs op de nieuwe merge-SHA, een echte heartbeat-/alarmtest, SendGrid Mail Send zonder 401 en bewijs dat Duindorp staging, Duindorp production en Castivo afzonderlijke Linux-users/rootless sockets/runners gebruiken.
