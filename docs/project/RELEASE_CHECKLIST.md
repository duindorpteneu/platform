# Releasechecklist

Status: gateformulier; geen deploymentautorisatie
Release: `________________`
Commit-SHA: `________________`
Canon: MVP v1.0 plus goedgekeurd addendum v1.1
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
- [ ] Alle GitHub Actions zijn op volledige commit-SHA gepind en actionlint is groen.
- [ ] `pnpm lint` slaagt.
- [ ] `pnpm typecheck` slaagt.
- [ ] `pnpm test` slaagt.
- [ ] `pnpm build` slaagt.
- [ ] Een geïsoleerde lokale Supabase-stack start zonder andere projecten/processen te wijzigen.
- [ ] `pnpm db:reset` past alle migraties en seed vanaf nul toe.
- [ ] `pnpm test:db` slaagt, inclusief negatieve RLS- en autorisatietests.
- [ ] `pnpm test:db:upgrade:phase-b` bewaart alle legacyhashes en reconciliaties.
- [ ] `pnpm test:db:concurrency` bewijst dat dubbele uitgifte niet mogelijk is.
- [ ] `pnpm test:staff-mfa` bewijst AAL2-toegang en AAL1-weigering.
- [ ] `pnpm test:dashboard-browser` slaagt en ruimt fixtures/processen op.
- [ ] `pnpm test:portal-access-browser` en `pnpm test:a11y` slagen.
- [ ] `pnpm test:e2e` slaagt voor alle lokaal automatiseerbare canonieke scenario’s.
- [ ] Securityacceptatie in [SECURITY_ACCEPTANCE.md](SECURITY_ACCEPTANCE.md) heeft geen lokale blocker.
- [ ] Responsiviteit, loading/empty/error/success en WCAG-kernflows zijn gecontroleerd.
- [ ] Migraties zijn additief/forward-only; er is geen toegepaste migratie gewijzigd.
- [ ] Release-, risico-, besluit- en testevidence-documentatie is actueel.

Bewijs lokale gate: `____________________________________________________________`

## B. Stagingvoorbereiding

- [ ] CI op exact deze commit-SHA is volledig groen.
- [ ] De stagingdeploy heeft de canonieke CI-workflow-ID, push/main/SHA en beide verplichte jobs machine-verifieerbaar gecontroleerd.
- [ ] App-runtime en Supabase staan in een EU- of gelijkwaardig privacygeschikte regio.
- [ ] Staging en production hebben verschillende apphosts, Supabase-projecten, Auth-tenants en secrets.
- [ ] Staging bevat uitsluitend fictieve `example.invalid`-gegevens of aantoonbaar geanonimiseerde data.
- [ ] HTTPS, HSTS, CSP, veilige cookies en securityheaders zijn actief.
- [ ] Caddy 2.10+ heeft de vier niet-overlappende bodylimietmatchers actief; per routegroep bereikt exact de decimale grens de HMAC-no-opbranch met gemarkeerde `204` en geeft grens+1 uitsluitend een markerloze proxy-`413`.
- [ ] Providers starten uit: `MOLLIE_ENABLED=false` en `EMAIL_ENABLED=false`.
- [ ] Stagingsecretstore is gevuld; geen secret staat in Git, CI-output of deploymentlog.
- [ ] Publieke `/api/health` en bearer-beveiligde `/api/internal/health` zijn gemonitord.
- [ ] E-mailworker draait iedere minuut; retentiejob bij start en uiterlijk iedere vijf minuten; een e-mailfout blokkeert cleanup niet en gemiste runs alarmeren.
- [ ] De importstaging-sleutelgate draait na migraties en vóór appactivatie; wijzigen of verwijderen van de key blokkeert zolang actieve uploads bestaan.
- [ ] Back-upmogelijkheid en geïsoleerde restorebestemming zijn bevestigd.
- [ ] Fictieve testaccounts voor beheerder, kledingcommissie, uitgifte en ouderflows zijn ingericht met TOTP waar vereist.
- [ ] Releaseversie, commit-SHA en canonversie zijn zichtbaar/vastgelegd.
- [ ] Releaseimage, SPDX-SBOM en manifest hebben een groene high/critical containerscan, `SHA256SUMS` en een geverifieerde keyless Sigstore/Cosign-bundel via GitHub OIDC.

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
- [ ] SendGrid: SPF/DKIM/afzender, template, Mail Send, echte TLS-IMAP-inbox, tweemaal signed webhook, retry en deduplicatie zijn uitgevoerd.
- [ ] E-mail- en Mollie-safety switches zijn tijdens een gecontroleerde test uit- en ingeschakeld.
- [ ] Health, queue, webhookfouten en betaalverschillen zijn tijdens acceptatie zichtbaar.
- [ ] Retentiejob is tweemaal uitgevoerd en idempotentie/cutoffs zijn bewezen.
- [ ] Geïsoleerde restore-drill gebruikt een snapshot jonger dan 24 uur en voltooit binnen vier uur; managed production-RPO heeft afzonderlijk providerbewijs.
- [ ] Incidenttabletops voor staffaccount, gelekte QR, verdachte betaling en datalek zijn afgerond.
- [ ] Er zijn geen blocker/critical/high securitybevindingen zonder expliciet stopbesluit.

Stagingbesluit: `GO / NO-GO`
Bewijs en ondertekening: `_______________________________________________________`

## D. Production-gate

Deze sectie geeft geen toestemming om productie te wijzigen. Uitvoering vereist een afzonderlijk changebesluit.

- [ ] Staging is groen op exact de te releasen commit-SHA en migratieset.
- [ ] Deploy-, core-, Phase-B-, Mollie-, SendGrid-, restore-, rollback- en operationsattestaties verwijzen naar exact dezelfde SHA en artifactdigest.
- [ ] Alle acht workflow-run-ID's zijn uniek, maximaal 48 uur oud en de acceptatieruns zijn pas na de deploy gestart.
- [ ] De applicatierollbackdrill bewijst exact huidige kandidaat → actuele productionrelease → kandidaat. Tijdens de eerste overgang is daarnaast de signed legacy-adoptierun gebonden.
- [ ] Productieback-up/herstelpunt is succesvol en maximaal 24 uur oud.
- [ ] Het encrypted pre-migration-herstelpunt is vóór mutatie geüpload, uit Actions teruggedownload en checksumgelijk bewezen.
- [ ] Forward-fixplan, approllbackcompatibiliteit en eigenaar zijn bevestigd.
- [ ] Productionsecrets zijn onafhankelijk van staging en rotatiedata zijn bekend.
- [ ] Migraties worden vóór appdeploy uitgevoerd.
- [ ] Productiedeploy vereist een via API bewezen onafhankelijke required reviewer met `prevent_self_review=true`.
- [ ] Smokeplan bevat stafflogin/MFA, ouder-OTP, orderdashboard, handmatige testbetaling, QR-lookup en mailjob.
- [ ] `EMAIL_ENABLED` blijft uit tot de productiemail-smoke is goedgekeurd.
- [ ] `MOLLIE_ENABLED` blijft uit tot live webhooktest en reconciliatiecontrole zijn goedgekeurd.
- [ ] Monitoring, incidentbezetting en rollback/forward-fixvenster zijn actief.
- [ ] Releaseversie en canonversie staan in de backofficefooter.

Productiebesluit: `GO / NO-GO`
Goedkeurders: `________________ / ________________`
Immutable artifactdigest: `________________`

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
