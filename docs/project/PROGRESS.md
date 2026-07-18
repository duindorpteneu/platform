# Progress

## Current phase
Phase 5 inventory, fulfilment and the data-backed deliveries workspace are validated; staff Auth/MFA is next.

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

## In progress
- Supabase staff authentication/MFA en het fixturevrije backofficedashboard zijn nog niet aangesloten.
- QR-rotatie/intrekking en fulfilmentcorrectie zijn nog niet gebouwd.

## Next
- Sluit staff Auth/MFA en echte medewerkergegevens op de shell aan.
- Vervang daarna de backoffice-dashboardfixtures door geautoriseerde operationele aggregaties.

## Blockers
- Live Mollie- en SendGrid-credentials zijn voor de volgende lokale bouwstappen niet nodig; alleen live providerverificatie blijft extern geblokkeerd.
