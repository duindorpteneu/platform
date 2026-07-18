# Securityacceptatie

Status: gateformulier tot en met stagingverificatie
Commit-SHA: `________________`
Omgeving: `local / staging`
Reviewer en datum: `________________`

Een controle is alleen groen met reproduceerbaar bewijs. Gebruik fictieve data, redigeer identifiers en noteer nooit credentials, OTP’s, sessiecookies, QR-tokens of volledige webhookpayloads.

## 1. Geautomatiseerde baseline

| Gate | Commando | Resultaat/bewijs |
| --- | --- | --- |
| Locked dependencies | `pnpm install --frozen-lockfile` | `________________` |
| High-confidence secret scan | `node scripts/check-secrets.mjs` | `________________` |
| Forward-only migration lint | `node scripts/check-migrations.mjs` | `________________` |
| Dependency audit | `pnpm audit --prod --audit-level high` | `________________` |
| Lint | `pnpm lint` | `________________` |
| Typecheck | `pnpm typecheck` | `________________` |
| Unit/integratie | `pnpm test` | `________________` |
| Productiebuild | `pnpm build` | `________________` |
| Schone migratie/seed | `pnpm db:reset` | `________________` |
| Database/RLS | `pnpm test:db` | `________________` |
| Uitgifteconcurrency | `pnpm test:db:concurrency` | `________________` |
| Staff MFA | `pnpm test:staff-mfa` | `________________` |
| Browserregressie | `pnpm test:dashboard-browser` | `________________` |
| Canonieke Playwrightsuite | `pnpm test:e2e` | `________________` |

De lokale secret scan is defense-in-depth en vervangt de secretstore, GitHub push protection of periodieke provider-keyreview niet. Een gevonden mogelijke key wordt ingetrokken en geroteerd; alleen uit Git verwijderen is onvoldoende.

## 2. Identiteit, sessies en autorisatie

- [ ] Er bestaan exact drie staffrollen: `beheerder`, `kledingcommissie`, `uitgifte`.
- [ ] Iedere staffroute en RPC vereist een actief profiel en TOTP/AAL2; AAL1 wordt geweigerd.
- [ ] Geblokkeerd staffaccount en eerder uitgegeven sessie verliezen direct toegang.
- [ ] `uitgifte` ziet alleen lookup/uitgiftedata en krijgt 403/redirect zonder bodydata op backoffice-, export- en beheergrenzen.
- [ ] Kledingcommissie kan operationele taken uitvoeren maar geen beheerder-only staff-/systeemactie.
- [ ] Ouders hebben geen Supabase Auth-account, wachtwoord of magic link.
- [ ] Ouder-OTP is cryptografisch willekeurig, exact zes cijfers, alleen gehasht opgeslagen, tien minuten geldig, single-use en maximaal vijf pogingen.
- [ ] Alleen een bekend actief kandidaat-e-mailadres kan een bruikbare challenge/mail opleveren.
- [ ] Bekend en onbekend e-mailadres leveren dezelfde neutrale responsevorm/copy.
- [ ] Oudersessie is opaque en gehasht, herroepbaar en via `Secure; HttpOnly; SameSite` cookie zonder token in URL.
- [ ] Logout/intrekking maakt een gekopieerde oude sessie direct ongeldig.
- [ ] Ouder krijgt voor ieder niet-gekoppeld `member_id` 403/404 zonder lidmetadata.
- [ ] QR-plaintext staat niet in database, logs, URL-querystring of analytics; rotatie maakt oude token direct ongeldig.

Bewijs: `________________`

## 3. Autorisatiematrix

Test zowel pagina als directe API/RPC; client-side verborgen knoppen tellen niet.

| Functie | Anoniem | Ouder gekoppeld | Beheerder | Kledingcommissie | Uitgifte |
| --- | --- | --- | --- | --- | --- |
| Backoffice lezen | Weigeren | Weigeren | Toestaan | Toestaan binnen operatie | Weigeren |
| Staff-/systeembeheer | Weigeren | Weigeren | Toestaan | Weigeren | Weigeren |
| Import/catalogus/orders | Weigeren | Weigeren | Toestaan | Toestaan | Weigeren |
| Kas/pin exact registreren | Weigeren | Weigeren | Toestaan | Toestaan | Weigeren |
| Exports/audit | Weigeren | Weigeren | Toestaan | Alleen canoniek operationeel | Weigeren |
| Eigen gekoppelde lidkaart | Weigeren | Toestaan | Niet via ouderroute | Niet via ouderroute | Weigeren |
| Niet-gekoppelde lidkaart | Weigeren | Weigeren | Niet van toepassing | Niet van toepassing | Weigeren |
| QR-lookup/uitgifte | Weigeren | Weigeren | Volgens canon | Volgens canon | Toestaan, minimale data |
| Correctie/QR-rotatie | Weigeren | Weigeren | Toestaan | Toestaan | Weigeren |

Negatief bewijs bevat HTTP-status plus controle dat geen gevoelige responsebody of databasewijziging ontstond.

Bewijs: `________________`

## 4. Browserrequestbeveiliging

- [ ] Alle state-changing browsergrenzen gebruiken uitsluitend POST/PATCH/DELETE.
- [ ] Centrale requestguard valideert exact de canonical `APP_BASE_URL`-Origin én Host vóór bodyparse/domeinactie.
- [ ] Ontbrekende, `null`, vreemde of sibling-subdomain Origin wordt geweigerd.
- [ ] Ontbrekende/gespoofte Host, forwarded host of ambiguë kommaheader wordt geweigerd.
- [ ] `Sec-Fetch-Site` moet `same-origin` zijn; cross-site/none op browsermutaties wordt geweigerd.
- [ ] Webhooks zijn expliciet uitgezonderd van browser-CSRF maar hebben eigen providerauthenticiteit en idempotentie.
- [ ] Interne jobs zijn expliciet uitgezonderd en gebruiken constant-time bearercontrole met `CRON_SECRET`.
- [ ] Cookie-`SameSite` is aanvullend en niet de enige CSRF-maatregel.
- [ ] Afwijzing vindt plaats vóór database- of providercall.
- [ ] Alleen de bekende deploymentproxy mag forwarded headers zetten; directe clientheaders worden aan de edge overschreven.

Test minimaal: geldige origin/host, ontbrekende origin, `Origin: null`, vreemde origin, sibling-subdomain, ontbrekende host, gespoofte host, dubbele forwarded host, HTTP/HTTPS-mismatch en geldige proxyheaders.

Bewijs: `________________`

## 5. Rate limits en misbruik

- [ ] OTP-aanvraag: minimaal 60 seconden tussen aanvragen, maximaal vijf per uur per e-mail en aanvullende IP-limiet.
- [ ] OTP-verificatie: maximaal vijf pogingen per challenge plus begrensde e-mail/IP-scope; nieuwe aanvragen omzeilen eerdere limiet niet.
- [ ] Mollie-create, QR-lookup, zoeken en exports hebben database-/shared-storelimieten die meerdere appinstances niet omzeilen.
- [ ] Rate-limitkey is gehasht; langdurige audit bevat geen rauw IP-adres.
- [ ] Gelijktijdige requests overschrijden de limiet niet door race conditions.
- [ ] Overschrijding geeft `429` waar dat geen enumeratie veroorzaakt; OTP-response blijft neutraal.
- [ ] Rate-limit-events worden uiterlijk na 30 dagen verwijderd, behoudens gedocumenteerd incidentbewijs buiten de normale store.

Bewijs met grens-1, grens, grens+1 en reset na window voor iedere scope.

Bewijs: `________________`

## 6. Input, upload en output

- [ ] Zod en lengte-/formaatallowlists beschermen iedere servergrens.
- [ ] JSON-routes eisen correct Content-Type en begrenzen declared én werkelijk gelezen body.
- [ ] Sportlinkupload controleert requestgrootte vóór buffering waar de runtime dit ondersteunt, maximaal 10 MB, `.csv`-extensie, MIME, UTF-8/leesbare CSV en inhoud.
- [ ] CSV-parser begrenst rijen, kolommen en cellengte; binaire, polyglot en formuleachtige invoer wordt veilig geweigerd/weergegeven.
- [ ] Upload wordt nooit uitgevoerd en niet publiek/permanent opgeslagen.
- [ ] HTML-output gebruikt escaping/sanitizing; productie bevat geen onbetrouwbare `dangerouslySetInnerHTML`.
- [ ] CSV en XLSX neutraliseren iedere tekstcel die begint met `=`, `+`, `-`, `@`, tab of carriage return.
- [ ] CSV heeft UTF-8 BOM; exportbestandsnaam bevat seizoen/datum en geen ledennaam.
- [ ] Exporttype en werkelijk toegepaste serverfilters staan in audit.

Bewijs: `________________`

## 7. Securityheaders en transport

Controleer productieachtige stagingresponses voor normale pagina, API JSON/download, redirect, 404 en 500:

- [ ] HTTPS-only; HTTP redirect zonder gevoelige body.
- [ ] `Strict-Transport-Security: max-age=31536000; includeSubDomains`.
- [ ] CSP met minimaal `default-src 'self'`, `base-uri 'self'`, `object-src 'none'`, `frame-ancestors 'none'` en allowlists voor noodzakelijke Supabase HTTPS/WSS.
- [ ] Productie-CSP bevat geen `unsafe-eval`; geen providerwildcards die Mollie/SendGrid secrets of frames toelaten.
- [ ] `X-Content-Type-Options: nosniff`.
- [ ] `Referrer-Policy: strict-origin-when-cross-origin`.
- [ ] `Permissions-Policy` zet ongebruikte sensoren uit en camera alleen waar uitgiftescan dit nodig heeft.
- [ ] `X-Frame-Options: DENY` als legacyverdediging naast CSP.
- [ ] `Cross-Origin-Opener-Policy: same-origin` en compatibele resourcepolicy.
- [ ] Gevoelige pagina/API/download gebruikt `Cache-Control: private, no-store` of `no-store`.
- [ ] Correlation-id is een geldige UUID, wordt teruggegeven en een onbetrouwbare clientwaarde wordt vervangen.

Bewijs: `________________`

## 8. Database, integraties en audit

- [ ] RLS staat standaard dicht; grants zijn least privilege; `private` is niet via Data API exposed.
- [ ] Databaseconstraints bewaken één order per lid/seizoen, integer centen, geldige transities en geen dubbele uitgifte.
- [ ] Kritieke samengestelde mutaties gebruiken transactie/locking en falen atomair.
- [ ] Normale rollen kunnen audit niet wijzigen/verwijderen; servicefuncties schrijven alleen allowlisted, geredigeerde metadata.
- [ ] Mollie checkout gebruikt exact EUR-bedrag uit server/database en hosted HTTPS-URL op mollie.com.
- [ ] Redirect markeert nooit paid; webhook haalt status opnieuw bij Mollie op en vergelijkt provider-ID, order, metadata, valuta en bedrag.
- [ ] Webhookreplay, vertraging en gelijktijdigheid veroorzaken geen dubbele betaling, e-mail of QR-actie.
- [ ] SendGrid signed webhook valideert key, handtekening en freshness window vóór verwerking.
- [ ] E-mailqueue gebruikt idempotency, maximaal vijf pogingen, backoff en veilige claim/complete-semantiek.
- [ ] Logs/audit slaan geen providersecret of volledige webhookpayload op.
- [ ] Safety switches blokkeren alleen provideractie en verwijderen geen handmatige administratie.

Bewijs: `________________`

## 9. Logging, privacy en retentie

- [ ] Operationele logger accepteert alleen allowlisted velden en redigeert overige data.
- [ ] Tests bewijzen dat e-mail, naam, OTP, sessie-/QR-token, Authorization, cookie, providerkey en webhookbody niet worden gelogd.
- [ ] Correlation-id verbindt app-, database- en provideractie zonder PII als correlatiesleutel.
- [ ] Publieke health bevat alleen status/versie; interne health bevat alleen operationele tellingen.
- [ ] OTP fysiek verwijderd uiterlijk 24 uur na gebruik/verloop.
- [ ] Oudersessie verwijderd uiterlijk 30 dagen na expiratie/intrekking.
- [ ] E-mailprovider-events maximaal 12 maanden; rate-limit-events maximaal 30 dagen.
- [ ] Uitgiftehistorie minimaal twee volledige seizoenen en daarna review/anonymisering.
- [ ] Financiële administratie zeven jaar wanneer fiscaal vereist.
- [ ] Audit minimaal 24 maanden; betaalgerelateerde audit volgt financiële retentie.
- [ ] Verwijderen ouderlink verwijdert geen betaling of uitgiftehistorie.
- [ ] Cleanupjob is idempotent, bearer-beveiligd en rapporteert alleen aantallen.

Bewijs: `________________`

## 10. Operations en herstel

- [ ] Dagelijkse productionback-up en controle op leeftijd jonger dan 24 uur zijn ingericht.
- [ ] Geïsoleerde restore-drill voldoet aan RPO 24 uur en RTO 4 uur.
- [ ] E-mailworker, retentiejob en healthmonitor alarmeren op gemiste/stale/foute toestand.
- [ ] Incidentprocedures staffaccount, QR, verdachte betaling en datalek zijn getabletopt.
- [ ] Keys zijn per omgeving gescheiden en rotatie is getest zonder waarden in bewijs.
- [ ] `PARENT_TOKEN_PEPPER` wordt niet ongecoördineerd geroteerd; sessie-/QR-impact heeft expliciet plan.
- [ ] Forward-fixplan wijzigt geen toegepaste migratie en approllback vereist schemacompatibiliteit.

Bewijs: `________________`

## 11. Besluit

- [ ] Geen blocker/critical/high bevinding staat open.
- [ ] Alle negatieve tests bewijzen ook “geen dataresponse/geen mutatie”.
- [ ] Afwijkingen hebben canonieke goedkeuring, eigenaar en deadline.
- [ ] De geteste commit-SHA is exact het stagingartefact.

Besluit: `PASS / FAIL`
Open bevindingen: `______________________________________________________________`
Reviewer: `________________`
Datum: `________________`
