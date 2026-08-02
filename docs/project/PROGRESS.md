# Progress

## Current phase
Fase B is op 2 augustus 2026 expliciet goedgekeurd. Het bindende addendum v1.1 legt het pakket-/lid-seizoenmodel, DOB-toegang, dynamische import, selectieve oudergrants, allocatiegebonden QR, scanner-PWA en staging-opschoning vast. Implementatie start forward-only en achter standaard uitgeschakelde compatibilityflags; production blijft geblokkeerd.

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
- Eén `deploy.yml`, Dockerfile, veilige Composeconfiguratie, centrale `deploy-vps.sh`, atomische revision/manifests, runtime-Supabasebootstrap, `/admin`-alias en releasebewuste healthchecks toegevoegd.
- Rootrouting hersteld naar het ouderportaal; OTP-verificatie bevat geen e-mailadres meer in URL/history en gebruikt een versleutelde korte HttpOnly challengecookie.
- Mollie checkout en reconciliatie routeren hosted PostgREST-RPC's nu expliciet naar hun werkelijke `public`- respectievelijk `app`-schema; unitregressie dekt deze scheiding.
- SendGrid-events correleren via de bestaande niet-persoonlijke `email_job_id` in plaats van de afwijkende HTTP- en webhook-message-ID's; events zonder `sg_message_id` blijven idempotent verwerkbaar.
- De staffuitnodiging verwerkt Supabase's invite-fragment client-side, wist het fragment direct, biedt een veilige wachtwoordinstelpagina en stroomt verplicht door naar TOTP; de eerste stagingbeheerder blijft een expliciete eenmalige Supabase-bootstrap.
- Staging heeft repository-native operationele en provider-smokeworkflows; production wordt hierdoor niet aangeraakt.
- Native Sportlink-ledenexports met `Rel. code`, `Roepnaam` en `Lokale teams` worden ondersteund; ontbrekende seizoenstatus, team en roepnaam krijgen expliciete previewdefaults. De aangeleverde 528-rijen-CSV valideert volledig zonder persoonsgegevens in testartefacten.
- Beheerders kunnen open seizoenen met datums en standaardbedrag aanmaken en optioneel direct activeren; beheerder en kledingcommissie kunnen artikelen per open seizoen in bulk koppelen/ontkoppelen en leden met verplichte auditreden activeren/inactiveren. Inactieve leden behouden alle historie maar kunnen geen nieuwe bestelling, handmatige betaling of Mollie-poging krijgen.
- Teamfiltering is operationeel in het ledenoverzicht. Beheerder en kledingcommissie kunnen na een server-side, kortlevend ondertekende snapshotpreview alle leden van een exact team geaudit activeren/inactiveren en expliciet gekozen artikelvarianten/maten aan geschikte teamleden toevoegen. Bestaande maten en bedragen blijven staan; betaalde orders en inactieve leden worden overgeslagen en snapshotdrift wordt vóór mutatie geweigerd.
- Verenigingsgegevens en een optioneel afwijkend afhaaladres zijn gestructureerd en geaudit beheerbaar. Instellingen kunnen ook vóór het eerste seizoen worden opgeslagen; de migrations leveren zelf de singleton-instellingenrij en seizoenaanmaak retourneert direct de actuele workspace.
- Beheerder en kledingcommissie kunnen per actief lid, open seizoen en gekoppeld artikel een door ouders doorgegeven maat vastleggen. Bestelregels blijven leidend en alleen-lezen; maatprofielen wijzigen nooit automatisch betaling, voorraad of uitgifte.
- De settings-release ververst hosted PostgREST nu expliciet en iedere deployment controleert vóór applicatie-activatie via een service-only, gegevensvrije contractprobe dat de drie nieuwe settings-RPC's zichtbaar zijn en hun `authenticated`-rechten behouden. De settings-foutstatus wijst niet langer ten onrechte naar MFA terwijl de AAL2-layout actief is.
- De gedeelde medewerkersshell heeft onder `lg` een rolgefilterde mobiele drawer met dezelfde werkruimte- en beheerlinks als desktop, actuele seizoencontext en uitloggen. De 44px-menuknop, actieve linkstatus, scroll-lock, overlay, Escape, focus-terugkeer en focus-trap zijn in de echte AAL2-browserflow afgedekt.
- De settingsworkspace retourneert bij ontbrekend actief seizoen nu altijd een boolean per seizoen. Exacte staging-SHA `76bfe4ef4a5e4348668c37647e8b72e3299a98c9` is groen voor immutable deploy/migration (`29873523343`), echte drie-rollen-MFA/settings/mobile-acceptatie (`29873991736`) en een netwerkgeïsoleerde backup/restore-drill (`29874124335`).
- Phase B expandmigratie 61 voegt expliciete lid-seizoenen, private DOB, exacte externe identiteiten, review-only oudergrants, pakkettemplates/revisies, immutable order-/product-/uitgiftesnapshots en standaard uitgeschakelde releaseflags toe. Legacyorders krijgen uitsluitend `Legacy tenue`; er worden geen pakketten, producten of maten gegokt of geseed.
- De echte upgradegate start blijvend op migration 60, laadt twee fictieve legacyorders met betaling, voorraad, reserveringen, QR, deeluitgifte en gedeeld ouderadres, vergelijkt alle oude bedrijfsvelden via SHA-256 en reconcilieert geld, voorraad en uitgifte. Clean replay en upgrade zijn groen; 23 pgTAP-bestanden leveren nu 613 asserties.
- Beheerderdetail gebruikt de afgeschermde v3-RPC en toont DOB; kledingcommissie krijgt aantoonbaar null en uitgifte wordt geweigerd. Een expliciet gekoppelde ouder ziet de DOB van alleen dat actieve lid-seizoen. Zelf koppelen op een gedeeld e-mailadres is server-side geblokkeerd en uit de ouder-UI verwijderd.

## In progress
- Phase B slice 0 is lokaal afgerond: reproduceerbare baseline, canonaddendum, security-/releasefundering, expandmigratie en upgrade-reconciliatie.
- De eerder gemelde dependencybaseline is opnieuw gemeten op 14 advisories (9 high, 5 moderate). Next.js, Sharp, PostCSS en alle aanwezige `brace-expansion`-majors zijn naar gepatchte versies vastgezet; `pnpm audit --audit-level high` is nu groen en een harde CI-/deploygate.
- Alle muterende API-routes hebben nu een expliciete bodypolicy met werkelijke streamlimieten voor bytes, tijd en fragmentatie; chunked en gecomprimeerde bypasses, directe bodyconsumers en bodies op inhoudsloze mutaties worden geweigerd. Sportlink gebruikt een begrensde raw-CSV-upload, SendGrid verifieert de exacte bytes vóór parsing en Mollie-webhook- en providerresponses zijn begrensd. De Caddy-referentie heeft niet-overlappende edgecaps en iedere staging-/productiondeploy blokkeert voortaan zonder vier succesvolle publieke chunked proxyprobes.
- Alle staging-specifieke Mollie-fixture-RPC's zijn via forward migration 60 uit het productschema verwijderd. De acceptance-run gebruikt nu uitsluitend een exact stagingproject/TLS-gebonden, digest-gepinde directe SQL-runner; prepare vereist bestaande stagingconfiguratie en verandert geen seizoen/providerflag. Een echte lokale SQL-integratietest bewijst idempotente prepare/state/cleanup en iedere deploy blokkeert zolang een van vier oude RPC's nog via PostgREST zichtbaar is.
- Staging draait publiek gezond op main-SHA `7e50810e77bf1d65c3c95af2930e35ee0a0cf329`. CI, immutable deploy/migrations en de echte Mollie paid/mismatch/replay/refund-aanmaakacceptatie zijn exact op deze SHA groen.
- Er is geen lokale codeblocker voor de afgetekende kernflows. De resterende releasegereedheid bestaat uit SendGrid-deliverability, externe monitoring, apparaatacceptatie, VPS-isolatie en een later werkelijk door Mollie naar `processing/refunded` gevorderde refundobservatie.
- Production is niet gewijzigd en blijft bewust achter de handmatige approvalgate.

## Next
- Bouw nu de beheer-RPC/UI voor pakketten en selectieve toegang en daarna dynamische import, allocatie, QR-exchange, mails en scanner-PWA als verticale slices.
- Voer de geautoriseerde staging-opschoning pas uit na de nieuwe migrations, targetassertie, back-up en tellingendry-run; behoud alle staff- en Auth-accounts.
- Leg bij een latere Mollie-overgang naar `processing` of `refunded` aanvullend live webhook-/QR-intrekkingsbewijs vast; de huidige testmode-refund bleef conform providercontract `pending` en lokaal ongewijzigd.
- Configureer een unieke `OPERATIONS_HEARTBEAT_URL` per omgeving en bewijs gemiste ping plus herstel; corrigeer daarnaast de SendGrid-key/scope totdat Mail Send 202 en inbox-/eventbewijs groen zijn.
- Rond de gekozen uitgifteapparaat-/browsermatrix en de afzonderlijke Linux-user/rootless-runnerboundaries voor Duindorp staging, Duindorp production en Castivo aantoonbaar af.
- Overweeg productionpromotie pas daarna en uitsluitend na expliciete approval.

## Blockers
- Geen lokale codeblocker.
- Extern ontbreekt `OPERATIONS_HEARTBEAT_URL` als uniek staging- en productionsecret. Productionpreflight blokkeert bewust zonder heartbeat.
- SendGrid Mail Send retourneert nog HTTP 401; OTP/inbox/delivery en providerfault-herstel kunnen daardoor niet live worden afgetekend.
- Production blijft NO-GO totdat de gedeelde VPS aantoonbaar afzonderlijke Linux-user/rootless-runnerboundaries voor Duindorp staging, Duindorp production en Castivo heeft.
