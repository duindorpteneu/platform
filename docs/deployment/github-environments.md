# GitHub environments

Audit uitgevoerd op 2026-07-19 via `gh` zonder secretwaarden uit te lezen. Environment branch policies laten uitsluitend `main` toe. Production heeft nog geen required-reviewerregel; dit is een externe releaseblocker.

## Variables

| Naam | Staging aanwezig | Production aanwezig | Validatie | Gebruikt door | Status/actie |
| --- | --- | --- | --- | --- | --- |
| `APP_HOST` | ja | ja | Exact eigen host | preflight, smokechecks | Stagingtypefout `dstaging-…` gecorrigeerd naar `staging-…` |
| `APP_BIND_PORT` | ja | ja | Exact 14000 / 24000 | Compose | correct |
| `NEXT_PUBLIC_APP_URL` | ja | ja | `https://` + `APP_HOST` | redirects, QR, callbacks, e-mail | correct |
| `SUPABASE_PROJECT_REF` | ja | ja | 20 lowercase tekens; verschillend | DB-/URL-koppeling | correct en verschillend |
| `NEXT_PUBLIC_SUPABASE_URL` | ja | ja | Exact `https://<ref>.supabase.co` | app/runtime | correct |
| `MOLLIE_ENABLED` | nee | nee | `false` of `true` | providergate | optioneel; default `false` in workflow |
| `EMAIL_ENABLED` | nee | nee | `false` of `true` | providergate | optioneel; default `false` in workflow |
| `SENDGRID_FROM_EMAIL` | nee | nee | geldig e-mailadres | SendGrid | vereist bij `EMAIL_ENABLED=true` |
| `SENDGRID_REPLY_TO_EMAIL` | nee | nee | geldig e-mailadres | SendGrid | vereist bij `EMAIL_ENABLED=true` |
| `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY` | nee | nee | niet leeg | webhookvalidatie | vereist bij `EMAIL_ENABLED=true` |

## Secrets

| Naam | Staging aanwezig | Production aanwezig | Validatie | Gebruikt door | Status |
| --- | --- | --- | --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | ja | ja | JWT, rol `anon` | publieke runtimebootstrap | aanwezig |
| `SUPABASE_SERVICE_ROLE_KEY` | ja | ja | JWT, rol `service_role` | serverdata | aanwezig |
| `SUPABASE_DB_URL` | ja | ja | PostgreSQL-URL identificeert eigen project-ref | migrations | aanwezig |
| `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | ja | ja | base64, exact 32 bytes | Next Server Actions | aanwezig |
| `PARENT_TOKEN_PEPPER` | nee | nee | uniek, minimaal 32 tekens | OTP/sessie/QR-hashing | ontbreekt, verplicht |
| `CRON_SECRET` | nee | nee | uniek, minimaal 16 tekens | interne jobs | ontbreekt, verplicht |
| `MOLLIE_API_KEY` | nee | nee | staging `test_`; production `live_` bij activering | betalingen | alleen vereist bij Mollie aan |
| `SENDGRID_API_KEY` | nee | nee | `SG.`-vorm | e-mail | alleen vereist bij e-mail aan |

Exacte interactieve commando's (gebruik geen `--body`):

```bash
gh secret set PARENT_TOKEN_PEPPER --repo duindorpteneu/platform --env staging
gh secret set CRON_SECRET --repo duindorpteneu/platform --env staging
gh secret set PARENT_TOKEN_PEPPER --repo duindorpteneu/platform --env production
gh secret set CRON_SECRET --repo duindorpteneu/platform --env production
```

Alleen vóór provideractivering:

```bash
gh secret set MOLLIE_API_KEY --repo duindorpteneu/platform --env staging
gh secret set SENDGRID_API_KEY --repo duindorpteneu/platform --env staging
gh secret set MOLLIE_API_KEY --repo duindorpteneu/platform --env production
gh secret set SENDGRID_API_KEY --repo duindorpteneu/platform --env production
```

`SUPABASE_ACCESS_TOKEN`, Resend-, NIKKI- en `MOLLIE_WEBHOOK_SECRET`-waarden worden niet gebruikt en horen daarom niet in dit contract. `PARENT_TOKEN_PEPPER` is het bestaande QR-/tokensigninggeheim. Secretwaarden verschijnen nooit in logs, manifests of documentatie.
