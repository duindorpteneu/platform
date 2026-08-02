# Releasechecklist

Status: gateformulier; geen deploymentautorisatie
Release: `________________`
Commit-SHA: `________________`
Canon: MVP v1.0
Releasebeheerder: `________________`
Datum/tijd (UTC): `________________`

Een vakje wordt alleen afgevinkt met een bewijslink of een opgeslagen commandoresultaat zonder secrets/PII. Een bekende rode gate, ontbrekend bewijs of afwijkende artefact-SHA is een stopbesluit.

## A. Lokale kandidaat

- [ ] Werkboom en bedoelde diff zijn beoordeeld; geen buildoutput, dump, fixture of `.env.local` wordt gereleased.
- [ ] Node.js 22 en pnpm 11.5.2 zijn gebruikt.
- [ ] `pnpm install --frozen-lockfile` slaagt.
- [ ] `node scripts/check-secrets.mjs` slaagt.
- [ ] `node scripts/check-migrations.mjs` slaagt.
- [ ] `pnpm audit --prod --audit-level high` heeft geen onbesproken high/critical bevinding.
- [ ] `pnpm lint` slaagt.
- [ ] `pnpm typecheck` slaagt.
- [ ] `pnpm test` slaagt.
- [ ] `pnpm build` slaagt.
- [ ] Een geïsoleerde lokale Supabase-stack start zonder andere projecten/processen te wijzigen.
- [ ] `pnpm db:reset` past alle migraties en seed vanaf nul toe.
- [ ] `pnpm test:db` slaagt, inclusief negatieve RLS- en autorisatietests.
- [ ] `pnpm test:db:concurrency` bewijst dat dubbele uitgifte niet mogelijk is.
- [ ] `pnpm test:staff-mfa` bewijst AAL2-toegang en AAL1-weigering.
- [ ] `pnpm test:dashboard-browser` slaagt en ruimt fixtures/processen op.
- [ ] `pnpm test:e2e` slaagt voor alle lokaal automatiseerbare canonieke scenario’s.
- [ ] Securityacceptatie in [SECURITY_ACCEPTANCE.md](SECURITY_ACCEPTANCE.md) heeft geen lokale blocker.
- [ ] Responsiviteit, loading/empty/error/success en WCAG-kernflows zijn gecontroleerd.
- [ ] Migraties zijn additief/forward-only; er is geen toegepaste migratie gewijzigd.
- [ ] Release-, risico-, besluit- en testevidence-documentatie is actueel.

Bewijs lokale gate: `____________________________________________________________`

## B. Stagingvoorbereiding

- [ ] CI op exact deze commit-SHA is volledig groen.
- [ ] App-runtime en Supabase staan in een EU- of gelijkwaardig privacygeschikte regio.
- [ ] Staging en production hebben verschillende apphosts, Supabase-projecten, Auth-tenants en secrets.
- [ ] Staging bevat uitsluitend fictieve `example.invalid`-gegevens of aantoonbaar geanonimiseerde data.
- [ ] HTTPS, HSTS, CSP, veilige cookies en securityheaders zijn actief.
- [ ] Caddy 2.10+ heeft de vier niet-overlappende bodylimietmatchers actief; de automatische publieke chunked proxyprobe geeft voor iedere routegroep `413`.
- [ ] Providers starten uit: `MOLLIE_ENABLED=false` en `EMAIL_ENABLED=false`.
- [ ] Stagingsecretstore is gevuld; geen secret staat in Git, CI-output of deploymentlog.
- [ ] Publieke `/api/health` en bearer-beveiligde `/api/internal/health` zijn gemonitord.
- [ ] E-mailworker draait iedere minuut; retentiejob dagelijks; gemiste runs alarmeren.
- [ ] Back-upmogelijkheid en geïsoleerde restorebestemming zijn bevestigd.
- [ ] Fictieve testaccounts voor beheerder, kledingcommissie, uitgifte en ouderflows zijn ingericht met TOTP waar vereist.
- [ ] Releaseversie, commit-SHA en canonversie zijn zichtbaar/vastgelegd.

Bewijs stagingconfiguratie: `_____________________________________________________`

## C. Stagingacceptatie

- [ ] Alle E2E-01 t/m E2E-18 in [STAGING_VERIFICATION.md](STAGING_VERIFICATION.md) zijn groen op exact deze artefact-SHA.
- [ ] Autorisatiematrix bewijst least privilege voor drie staffrollen, ouders en anonieme gebruiker.
- [ ] CSRF-, Origin-/Host-, rate-limit-, enumeratie-, upload- en bodylimiettests zijn groen.
- [ ] De publieke edgeprobe onderscheidt proxy-`413` van applicatie-`415` en is op exact deze staging-SHA groen.
- [ ] Securityheaders zijn gecontroleerd op pagina’s, API’s, redirects en foutresponses.
- [ ] Desktop-, tablet- en mobiele browsermatrix is uitgevoerd.
- [ ] Toetsenbord, labels, focus, contrast, foutmeldingen en reduced motion zijn beoordeeld.
- [ ] Mollie testmode: exact paid, mismatch, replay, delayed en refund/reconciliatie zijn uitgevoerd via publiek HTTPS-webhook.
- [ ] SendGrid: SPF/DKIM/afzender, template, sandbox/delivery, signed webhook, retry en deduplicatie zijn uitgevoerd.
- [ ] E-mail- en Mollie-safety switches zijn tijdens een gecontroleerde test uit- en ingeschakeld.
- [ ] Health, queue, webhookfouten en betaalverschillen zijn tijdens acceptatie zichtbaar.
- [ ] Retentiejob is tweemaal uitgevoerd en idempotentie/cutoffs zijn bewezen.
- [ ] Geïsoleerde restore-drill voldoet aan RPO 24 uur en RTO 4 uur.
- [ ] Incidenttabletops voor staffaccount, gelekte QR, verdachte betaling en datalek zijn afgerond.
- [ ] Er zijn geen blocker/critical/high securitybevindingen zonder expliciet stopbesluit.

Stagingbesluit: `GO / NO-GO`
Bewijs en ondertekening: `_______________________________________________________`

## D. Production-gate

Deze sectie geeft geen toestemming om productie te wijzigen. Uitvoering vereist een afzonderlijk changebesluit.

- [ ] Staging is groen op exact de te releasen commit-SHA en migratieset.
- [ ] Productieback-up/herstelpunt is succesvol en maximaal 24 uur oud.
- [ ] Forward-fixplan, approllbackcompatibiliteit en eigenaar zijn bevestigd.
- [ ] Productionsecrets zijn onafhankelijk van staging en rotatiedata zijn bekend.
- [ ] Migraties worden vóór appdeploy uitgevoerd.
- [ ] Productiedeploy vereist expliciete vier-ogen-goedkeuring en release-tag.
- [ ] Smokeplan bevat stafflogin/MFA, ouder-OTP, orderdashboard, handmatige testbetaling, QR-lookup en mailjob.
- [ ] `EMAIL_ENABLED` blijft uit tot de productiemail-smoke is goedgekeurd.
- [ ] `MOLLIE_ENABLED` blijft uit tot live webhooktest en reconciliatiecontrole zijn goedgekeurd.
- [ ] Monitoring, incidentbezetting en rollback/forward-fixvenster zijn actief.
- [ ] Releaseversie en canonversie staan in de backofficefooter.

Productiebesluit: `GO / NO-GO`
Goedkeurders: `________________ / ________________`
Release-tag: `________________`

## E. Directe stopcriteria

Stop de release bij:

- enig secret of productiegegeven in repository, logs, screenshots of testfixtures;
- niet-groene CI, migratie, RLS-, security-, E2E- of buildgate;
- bedrag-/valuta-/metadata-afwijking die paid kan worden;
- dubbele betaling, e-mail, QR-actie of uitgifte;
- onbekende of oudere artefact-SHA;
- ontbrekende dagelijkse back-up of mislukte restore-drill;
- onbereikbare health/scheduler/alerts;
- ontbrekend incident- of privacycontact;
- onduidelijke staging/production-scheiding;
- live provideractivatie zonder expliciete gate.
