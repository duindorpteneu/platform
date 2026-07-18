# Progress

## Current phase
Phase 5 inventory and fulfilment implementation in progress. Clean-database and RLS verification remain open.

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

## In progress
- De migraties moeten nog op een schone lokale Supabase/PostgreSQL-database worden uitgevoerd en met negatieve RLS- en concurrencytests worden bewezen.
- Supabase staff authentication/MFA en het fixturevrije backofficedashboard zijn nog niet aangesloten.
- De backoffice-interface voor levering aanmaken en wachtlijstselectie is nog niet aangesloten op de nieuwe stock endpoints.
- QR-rotatie/intrekking en fulfilmentcorrectie zijn nog niet gebouwd.

## Next
- Voer alle migrations en seed uit op een geïsoleerde lokale Supabase-stack en voeg database-integratietests toe voor voorraadoverschrijding, dubbele reservering en gelijktijdige uitgifte.
- Bouw daarna de datagedreven leveringenpagina voor ontvangst, variantwachtlijst en reserveringsbevestiging.

## Blockers
- De Supabase CLI en een lokaal Supabase PostgreSQL-image zijn niet aanwezig; daardoor is echte migratie-, RLS- en transactieverificatie lokaal nog geblokkeerd. Applicatiecode, unit tests en productiebuild kunnen wel verder.
- Live Mollie- en SendGrid-credentials zijn voor deze stap niet nodig.
