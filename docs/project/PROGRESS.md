# Progress

## Current phase
De lokale MVP-releasecandidate is functioneel, beveiligd en reproduceerbaar gevalideerd. Exports, instellingen, audit, operationele health/retentie, securityheaders, rate limits, CI en release-runbooks zijn afgerond. Een gescheiden self-hosted VPS-deploypad met GitHub-configuratiecontract, Supabase-migraties, standalone releases, systemd en Caddy is toegevoegd; VPS-bootstrap en providerverificatie blijven extern.

## Completed
- Starter governance and canon assets added.
- Next.js App Router foundation, route groups, shared shell and first enterprise dashboard added.
- TypeScript, ESLint and production build gates pass locally.
- Supabase foundation migration, local port contract, server client and staff-role guard added.
- Supabase middleware session refresh and configured staff-route gating added.
- Append-only audit, orders, order lines and payment foundation migration added.
- Sportlink CSV preview domain service and protected `/api/imports/preview` endpoint added.
- Ledenmodule, importpanel, catalogusmodule en consistente operationele placeholderroutes toegevoegd.
- Transactionele Sportlink commitfunctie en beschermde `/api/imports/commit` route toegevoegd.
- Exacte kas/pin-betalingsfunctie en beschermde `/api/payments/manual` route toegevoegd.
- Parent OTP, hashed session token and server-only SendGrid OTP adapter added.
- Canonieke ouderroutes `/login`, `/login/code` en staff-route `/staff/login` toegevoegd met werkende formulieren.
- Parent session/member RPCs and protected member, candidate, link and unlink endpoints added.
- Datagedreven ouderdashboard met member cards, artikelstatussen, betaalstatus en expliciete koppelkandidaten toegevoegd.
- Voorraadontvangsten, variantreserveringen, fulfilments, QR-tokenhashes en afgeleide orderstatussen als vooruitrolbare migrations toegevoegd.
- Handmatige betaling en eerste QR-activering in één database-transactie samengebracht.
- Beschermde stock receipt, reservation, QR lookup en atomaire fulfilment endpoints toegevoegd.
- Beperkte enterprise-uitgiftewerkruimte toegevoegd met camera-actie, neutrale ongeldige-QR-status, betaalblokkade en artikelselectie per status.
- QR lookup rate limiting, minimale persoonsgegevens, auditregistratie, live QR-hercontrole en dubbele-uitgifteconstraints toegevoegd.
- Betaalde ouderkaarten tonen de server-side gegenereerde actieve QR; onbetaalde kaarten blijven vergrendeld en de openbare QR-URL toont geen lidgegevens.
- Projectlokale Supabase CLI 2.109.1 en geïsoleerde Docker-stack toegevoegd; alle migrations en seed slagen vanaf een schone PostgreSQL 17-database.
- RLS en tabelprivileges aangescherpt zodat `uitgifte` geen leden/imports kan browsen en authenticated geen directe tabelmutaties kan uitvoeren.
- 18 pgTAP-asserties en een echte twee-sessies fulfilmentracetest toegevoegd en groen gemaakt.
- Rolbeveiligd voorraadoverzicht toegevoegd met totalen per variant, beschikbare ontvangstregels en variantgebonden wachtlijst.
- Datagedreven leveringenwerkruimte toegevoegd voor ontvangstregistratie, voorraadselectie en atomaire reserveringsbevestiging.
- De leveringenroute is zonder horizontale overflow gecontroleerd op desktop en mobiel; fout-, laad-, lege en successtatussen zijn aanwezig.
- Medewerkerslogin met sterk wachtwoord, TOTP enrollment/challenge, AAL2-middleware, serverguard en lokale sessie-intrekking toegevoegd.
- Staff-shell toont de echte profielnaam en rol; `uitgifte` krijgt uitsluitend de scanner-navigatie en kan niet naar backoffice doorlopen.
- AAL2 wordt ook in PostgreSQL fail-closed afgedwongen; een actief profiel met AAL1 krijgt `42501` op staff-RPC's.
- Volledige lokale browserflow wachtwoord → TOTP → backoffice → logout en reproduceerbare providerintegratietest zijn groen.
- Aparte AAL2-dashboard- en personeelsshell-RPC's toegevoegd met fail-closed rolcontrole en een minimale gegevensset zonder e-mailadressen.
- Dashboard-KPI's, recente bestelstatussen, auditactiviteit, actieve seizoencontext en gereed-voor-uitgifte-aantal zijn volledig datagedreven.
- Visuele dashboardfixtures, fictieve syncstatus, notificatieteller en fictieve uitgifteplanning zijn uit de backoffice verwijderd.
- Dashboard heeft loading-, error-, leeg-seizoen-, lege-lijst- en successtatussen; desktop en mobiel zijn zonder body-overflow gevalideerd.
- Zelfopruimende browserregressietest toegevoegd voor wachtwoord → TOTP → AAL2 → live dashboard, KPI's, fixtureverbod, routebeveiliging en screenshots.
- Operationeel ledenoverzicht toegevoegd met server-side zoeken, canonieke filters, paginering en een detailpaneel zonder volledige paginawissel.
- Lijst- en detaildata zijn gescheiden: de lijst bevat geen e-mailadressen; persoonsgegevens, ouderkoppelingen, orderregels, QR-status en historie komen uitsluitend via een expliciete detailquery.
- Sportlink-import afgerond als vierstappenflow met kolomkoppeling, nieuwe/gewijzigde/ongewijzigde tellingen en een transactionele, geaudite commit.
- Schone database-reset met 19 migrations, 75 pgTAP-asserties, 31 unit-tests en de productiebuild zijn groen.
- Zelfopruimende browserregressie bewijst AAL2, live dashboard, ledenlijst, filters, detail, desktop/mobiel, Sportlink preview/commit en anonieme routebeveiliging.
- Operationeel catalogusbeheer toegevoegd voor artikelen, seizoenskoppelingen, varianten, leverancierscodes, sortering en reversibel inactiveren zonder artikelprijzen.
- Operationeel bestelbeheer toegevoegd met ledenzoekfunctie, exact bedrag in eurocenten, één actieve regel per artikel, expliciete hoeveelheden en alleen-lezen betaalde orders.
- Database-invarianten toegevoegd voor exact betaalbedrag, immutable betaalde orderidentiteit, historische maatsnapshot en soft-cancelled regels die niet uitlekken naar ouder- of uitgifteviews.
- QR-rotatie, intrekking en expliciete heractivering toegevoegd met verplichte reden, monotone versie, directe invalidatie, hash-only opslag en service-only secretmutaties.
- Uitgiftehistorie en transactionele regelcorrecties naar Af te halen of Nalevering toegevoegd met behoud van oorspronkelijke fulfilment, reserveringssemantiek en auditspoor.
- Schone database-reset met 20 migrations, 127 pgTAP-asserties, 41 unit-/integratietests, concurrencytest, MFA-integratie, productiebuild en volledige browserreview zijn groen.
- Zelfopruimende browserreview bewijst cataloguscreate, variantcreate, orderupdate, paid immutability, QR rotate/revoke/reissue, fulfilmentcorrectie, desktop/mobiel en routebeveiliging.
- Zes canonieke e-mailtypen, gesloten shortcodes, fictieve previews, immutable job-snapshots, handmatige bulkselectie tot 2.000 orders en een duurzame SendGrid-jobqueue toegevoegd. De ouder-OTP-template is in dezelfde editor bewerkbaar en gebruikt `{{verificatiecode}}` uitsluitend tijdens vluchtige directe verzending.
- E-mailworker claimt maximaal 25 jobs met `SKIP LOCKED`, verwerkt begrensd parallel, gebruikt maximaal vijf pogingen en schakelt open-/kliktracking uit.
- SendGrid-eventwebhook valideert de raw-bodyhandtekening, dedupliceert `sg_event_id` en bewaart uitsluitend delivered, bounced, deferred, dropped en failed.
- Mollie Payments API hosted checkout, stabiele lokale idempotentie, klassieke webhook, provider-GET en exacte EUR/metadata-reconciliatie toegevoegd.
- Paid, drievoudige replay, mismatch/manual review, duplicate paid, authorized/pending en refund/QR-intrekking worden transactioneel en met een private redacted eventledger verwerkt.
- PII-minimale operationele betaalwerkruimte toegevoegd; `uitgifte` en AAL1 worden in PostgreSQL geweigerd.
- Schone database-reset met 30 migrations en 238 pgTAP-asserties, 92 applicatietests, lint, TypeScript, productiebuild en de uitgebreide AAL2-browserflow zijn groen.
- Zes geautoriseerde CSV/XLSX-exporttypen toegevoegd met server-side filters, limiet van 10.000 regels, UTF-8 BOM, veilige bestandsnamen, formule-injectieneutralisatie en audit.
- OTP-, verify-, Mollie-, export-, QR- en ledenzoeklimieten zijn server-side en in PostgreSQL afgedwongen; de gevonden zoek-digestfout is via een aparte forward-fixmigratie en regressietest hersteld.
- Browsermutaties hebben centrale Origin/Host/Fetch-Metadata/CSRF-proof- en bodygrenzen; Sportlink-upload heeft MIME/extensie/grootte/rij/kolom/cel/formulegrenzen.
- Productieheaders, actieve Next.js-middleware, correlation-id, no-store op private surfaces, publieke/interne health en beveiligde e-mail-/retentiejobs zijn toegevoegd.
- Beheerderinstellingen, exact drie staffrollen, veilige uitnodiging/blokkering, provider-safety switches en rolgescheiden auditviewer zijn AAL2-afgeschermd.
- Ouderlogout trekt de server-side sessie in; exact één kandidaat wordt na OTP expliciet automatisch gekoppeld, meerdere kandidaten nooit.
- CI, secret scan, forward-only migratielint, omgevingsmatrix, operationsrunbook, releasechecklist, securityacceptatie en stagingverificatieprocedure zijn toegevoegd.
- Definitieve lokale gates: 36 migrations schoon toegepast; 15 pgTAP-bestanden/383 assertions, 35 Vitest-bestanden/158 tests, concurrency, echte staff-MFA, lint, TypeScript, productiebuild en dependency-audit zijn groen.
- De volledige productie-browserflow is tweemaal achtereen groen en ruimt Auth, MFA en alle fictieve database-/e-mailfixtures aantoonbaar op.

## In progress
- Deploy van de exact gecommitte releasecandidate naar een afzonderlijke publieke HTTPS-stagingomgeving.
- Live SendGrid- en Mollie-testmodeverificatie, scheduler/alerts en geïsoleerde restore-oefening wachten op staginginfrastructuur en credentials.

## Next
- Doorloop `docs/project/STAGING_VERIFICATION.md` met uitsluitend fictieve data.
- Verifieer Mollie testmode, SendGrid-afzender/templates/webhook, staffuitnodiging, scheduler, alerts en restore-drill.
- Leg de geaccepteerde commit-SHA en alle externe bewijslinks vast voordat productie wordt overwogen.

## Blockers
- Geen lokale codeblocker.
- Externe staging-URL, afzonderlijk Supabase-project, secretstore, Mollie-testkey, SendGrid-configuratie en operationele eigenaren zijn nodig voor de resterende stagingverificatie.
