# Phase B release-evidence — 2026-08-07

Status: lokaal groen; gehoste stagingacceptatie en menselijke apparaattests nog
geblokkeerd. Dit document bevat geen secretwaarden of persoonsgegevens.

## Kandidaat en reproduceerbaarheid

- Branch: `codex/phase-b-package-platform`.
- Baseline vóór de Phase-B-commits:
  `3b445fd484b067dddd181bc2ff4b82147105d87c`.
- Package manager: `pnpm@11.5.2`; frozen install is groen.
- Supabase CLI: repository-gepind en via checksuminstaller gecontroleerd.
- PostgreSQL-restorebeeld:
  `public.ecr.aws/supabase/postgres:17.6.1.143` met vaste digest.
- Schema: 135 bestaande plus nieuwe forward-only migrationbestanden; geen
  historische migration herschreven.
- De uiteindelijke kandidaat-SHA, OCI-digest, SPDX-SBOM en checksums worden
  uitsluitend door de immutable GitHub-releaseworkflow vastgelegd.

## Lokale gates

| Gate | Resultaat |
| --- | --- |
| `pnpm install --frozen-lockfile --ignore-scripts` | groen |
| `pnpm typecheck` | groen |
| `pnpm lint` | groen |
| `pnpm lint:workflows` | groen, digest-gepinde actionlint zonder netwerk |
| `pnpm test` | 189 bestanden, 1.091 tests groen |
| `pnpm test:log-privacy` | 23 tests groen |
| `pnpm build` | production build groen |
| `pnpm security:secrets` | geen high-confidence credentials of runtime-envbestanden |
| `pnpm security:migrations` | 135 forward-only migrations groen |
| `pnpm security:dependencies` | geen bekende kwetsbaarheden |
| `pnpm test:db:upgrade:phase-b` | legacyhashes gelijk; reconciliatie groen |
| `pnpm db:reset` | alle migrations plus seed schoon |
| `pnpm test:db` | 53 pgTAP-bestanden, 1.740 assertions groen |
| Alle DB-concurrencygates | fulfilment, toegang, maataliassen, actiepunten, import, pakketten, betalingen, refund, voorraad, leveringnotificatie, mail, branding, OTP en supplier groen |
| `pnpm test:db:staging-cleanup` | 100 operationele tabellen gewist; 28 staff/Auth/configtabellen behouden |
| `pnpm test:capacity` | 1.500 leden, 10.000 regels, 25 sessies; staff p95 478 ms, QR p95 177 ms, uitgifte p95 797 ms |
| `pnpm test:staff-mfa` | AAL2 toegestaan, AAL1 geblokkeerd |
| `pnpm test:portal-access-browser` | gedeeld account, preflight, activate/revoke, mobiel en PII-vrije audit groen |
| `pnpm test:a11y` | backoffice, import met DOB, mail/branding, exports, scanner-PWA, mobile en geautomatiseerde a11y groen |
| Verse backup/restore | bron en netwerkloze PostgreSQL 17-restore exact gelijk; schema/ACL/RLS-contract groen |

De scanneracceptatie bewijst daarnaast: alleen de scanner is PWA, network-only,
persistente beveiligde staffsessie, fragment/direct-scan zonder QR-geheim in
query/history/storage, minimale voornaam/geslachtweergave, concrete
allocatiecontrole en dezelfde order-QR voor deel- en nalevering.

## GitHub-control-plane

Op 2026-08-07 alleen op namen en beleidsstatus gecontroleerd:

- `main` vereist strikt `Application quality gates` en
  `Supabase migration and pgTAP gates`;
- één onafhankelijke approval en last-push-approval zijn verplicht;
- adminhandhaving, lineaire historie en conversation resolution staan aan;
- force-push en branchdelete staan uit;
- staging en production accepteren alleen `main`;
- production heeft één required reviewer en is succesvol bijgewerkt met
  `prevent_self_review=true`;
- twee afzonderlijk gelabelde staging-/productionrunners zijn online.

De repository bewijst nog niet dat die runners werkelijk verschillende
Linux-users, private homes en Rootless-Docker-daemons gebruiken. Dat blijft een
externe releaseblokker.

## Environmentnamen zonder waarden

Aanwezig in staging: Supabase URL/anon/service-role/DB, Server Actions-key,
parent- en QR-pepper/version, cron, importkey/retentie, Mollie-testkey/profile,
SendGrid Mail Send-key/from/reply/webhook-public-key/webhook-ID/smoke-ontvanger,
JWKS en cleanup-backuppassphrase.

Aanwezig in production: Supabase URL/anon/service-role/DB, Server Actions-key,
parent- en QR-pepper/version, cron, importkey/retentie, Mollie-key/profile,
SendGrid Mail Send-key/from/reply/webhook-ID, JWKS en
production-backuppassphrase. `EMAIL_ENABLED`, `MOLLIE_ENABLED` en
`DYNAMIC_IMPORT_ENABLED` staan veilig uit.

Nog vereist vóór gehost groen:

- staging én production: `OPERATIONS_HEARTBEAT_URL`;
- staging: `SENDGRID_ADMIN_API_KEY`, `SENDGRID_API_KEY_FINGERPRINT`,
  `SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT`, `E2E_MAILBOX_IMAP_HOST`,
  `E2E_MAILBOX_IMAP_USER`, `E2E_MAILBOX_IMAP_PASSWORD`,
  `E2E_ADMIN_EMAIL`, `E2E_ADMIN_PASSWORD` en `E2E_ADMIN_TOTP_SECRET`;
- production: `SENDGRID_API_KEY_FINGERPRINT` en
  `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY`.

## Nog uit te voeren op exact dezelfde kandidaat

1. PR-review en beide vereiste CI-checks.
2. Eén immutable artifact met commit, digest, SBOM, checksums en
   Sigstore/Cosign-bundel.
3. Deploy naar staging met exact dat digest.
4. Staging Phase-B-, core-, Mollie-, SendGrid-inbox/event-, operations-,
   restore- en rollbackacceptatie.
5. De geautoriseerde staging-cleanup pas na encrypted backup/upload,
   netwerkloze restore, targetbewijs en dry-run; beheerders/Auth/config
   behouden.
6. Gemiste heartbeat plus herstel en echte SendGrid-bounce/drop/retry.
7. Menselijke scannerinstallatie/camera/permissions op de afgesproken echte
   apparaten en browsers.

`GROEN VOOR MENSELIJKE RELEASETESTS` mag pas worden afgegeven wanneer punten
1–6 groen en artifactgebonden zijn. Productie blijft buiten deze fase en wordt
niet automatisch gedeployed.
