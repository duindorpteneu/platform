# GitHub environments

Audit opnieuw uitgevoerd op 2026-08-15 via `gh` zonder secretwaarden uit te
lezen. Beide environments hebben een custom branch policy voor uitsluitend
`main`. `production` heeft twee bestaande repositorycollaborators als reviewers
en `prevent_self_review=true`; de promotieworkflow verifieert deze grens opnieuw
vóór een productionmutatie.

## Variables

| Naam | Staging aanwezig | Production aanwezig | Validatie | Gebruikt door | Status/actie |
| --- | --- | --- | --- | --- | --- |
| `APP_HOST` | ja | ja | Exact eigen host | preflight, smokechecks | Stagingtypefout `dstaging-…` gecorrigeerd naar `staging-…` |
| `APP_BIND_PORT` | ja | ja | Exact 14000 / 24000 | Compose | correct |
| `NEXT_PUBLIC_APP_URL` | ja | ja | `https://` + `APP_HOST` | redirects, QR, callbacks, e-mail | correct |
| `SUPABASE_PROJECT_REF` | ja | ja | 20 lowercase tekens; verschillend | DB-/URL-koppeling | correct en verschillend |
| `NEXT_PUBLIC_SUPABASE_URL` | ja | ja | Exact `https://<ref>.supabase.co` | app/runtime | correct |
| `SUPABASE_JWKS` | ja | ja | Compacte publieke ES256/P-256 JWKS van exact het eigen project | lokale staff-JWT-verificatie | bij signing-keyrotatie vóór activatie actualiseren |
| `MOLLIE_ENABLED` | ja (`false`) | nee | `false` of `true` | providergate | staging veilig uit; production workflowdefault `false` |
| `MOLLIE_PROFILE_ID` | als secret | als secret | exact verwacht `pfl_…` profiel | muterende Mollieacceptatie | actueel protected secret; workflow accepteert desgewenst ook een protected variable |
| `EMAIL_ENABLED` | ja (`false`) | nee | `false` of `true` | providergate | staging veilig uit |
| `DYNAMIC_IMPORT_ENABLED` | ja (`false`) | nee | `false` of `true` | dynamische-importgate | staging veilig uit |
| `IMPORT_RAW_RETENTION_HOURS` | ja (`24`) | nee | geheel getal 1–72 | raw-importretentie | staging correct; production ontbreekt |
| `QR_TOKEN_PEPPER_VERSION` | ja (`1`) | nee | geheel getal 1–9999 | actuele QR-keyversie | staging correct; production ontbreekt |
| `QR_TOKEN_PREVIOUS_PEPPER_VERSION` | nee | nee | geheel getal 1–9999, anders dan current | tijdelijk rotatievenster | alleen samen met previous pepper |
| `SENDGRID_FROM_NAME` | ja | nee | exact `Kledingcommissie Duindorp SV` | SendGrid | staging correct; production ontbreekt |
| `SENDGRID_FROM_EMAIL` | ja | aanwezig, niet herbevestigd | exact `kleding@duindorpsv.nl`, geverifieerd | SendGrid | staging correct; production blijft geblokkeerd |
| `SENDGRID_API_BASE_URL` | EU | EU | `https://api.eu.sendgrid.com` | SendGrid | expliciete EU-regional subuser |
| `SENDGRID_REPLY_TO_EMAIL` | ja | aanwezig, niet herbevestigd | exact `kleding@duindorpsv.nl` | SendGrid | staging correct; production blijft geblokkeerd |
| `SENDGRID_WEBHOOK_ID` | `fd290462-…` | `84500cb8-…` | UUID, omgevingsuniek | provider-smoke | production blijft ongevalideerd en uit |
| `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY` | ja | nee | geldige P-256 public key | webhookvalidatie | staging via de exacte signed-webhookconfiguratie opgehaald; production blijft uit |
| `SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT` | nee | nee | 64 lowercase hex; vooraf gecontroleerde SHA-256 van `username:user_id` | provider-smoke | verplicht vóór staging-webhookmutatie of Mail Send |

## Secrets

| Naam | Staging aanwezig | Production aanwezig | Validatie | Gebruikt door | Status |
| --- | --- | --- | --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | ja | ja | JWT, rol `anon`, exact eigen project-ref | publieke runtimebootstrap | aanwezig |
| `SUPABASE_SERVICE_ROLE_KEY` | ja | ja | JWT, rol `service_role`, exact eigen project-ref | serverdata | aanwezig |
| `SUPABASE_DB_URL` | ja | ja | Exact eigen directe Supabase-host of pooler-user; TLS niet uitgeschakeld | migrations | aanwezig |
| `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | ja | ja | base64, exact 32 bytes | Next Server Actions | aanwezig |
| `PARENT_TOKEN_PEPPER` | ja | ja | uniek, minimaal 32 tekens | OTP en oudersessies | aanwezig |
| `QR_TOKEN_PEPPER` | ja | nee | 32 random bytes, canoniek 43 tekens base64url | huidige QR-locator/grantkey | staging aanwezig; production ontbreekt |
| `QR_TOKEN_PREVIOUS_PEPPER` | nee | nee | andere canonieke 32-byte base64url-key | tijdelijk rotatievenster | optioneel en alleen samen met previous versie |
| `CRON_SECRET` | ja | ja | uniek, minimaal 16 tekens | interne jobs | aanwezig |
| `IMPORT_STAGING_ENCRYPTION_KEY` | ja | nee | 32 random bytes, canoniek 43 tekens base64url zonder padding | AES-256-GCM raw-importstaging | staging aanwezig; production ontbreekt |
| `OPERATIONS_HEARTBEAT_URL` | nee | nee | geheime `https://` dead-man-switch-URL zonder URL-userinfo | onafhankelijke schedulerbewaking | verplicht voor productiondeploy; staging optioneel maar aanbevolen |
| `MOLLIE_API_KEY` | ja | ja | staging `test_` of uitsluitend op de canonieke publieke cluborigin `live_`; production `live_` bij activering | betalingen | aanwezig; stagingacceptatie blijft altijd test-only |
| `SENDGRID_API_KEY` | ja | ja | `SG.`-vorm | e-mail | aanwezig; providerflag blijft standaard uit |
| `SENDGRID_ADMIN_API_KEY` | nee | niet van toepassing | dedicated stagingkey met uitsluitend user/webhook read-write | provider-smoke | verplicht vóór webhookconfiguratie |
| `SENDGRID_SMOKE_RECIPIENT` | ja | nee | vaste beheerde testontvanger | provider-smoke | waarde niet uitgelezen; provideracceptatie correleert op delivery-ID en signed event |
| `STAGING_CLEANUP_BACKUP_PASSPHRASE` | ja | niet van toepassing | unieke, hoog-entropische passphrase van minimaal 32 tekens | uitsluitend client-side encryptie/decryptie van de tijdelijke pre-wipeback-up | staging aanwezig; nooit als productionsecret gebruiken |
| `PRODUCTION_BACKUP_PASSPHRASE` | niet van toepassing | nee | unieke hoog-entropische passphrase van minimaal 32 tekens | encrypted herstelpunt vóór productiemigratie | ontbreekt; harde promotieblocker |

Bij toekomstige rotatie of provideractivering worden secrets uitsluitend interactief gezet (gebruik geen `--body`):

```bash
gh secret set MOLLIE_API_KEY --repo duindorpteneu/platform --env staging
gh secret set SENDGRID_API_KEY --repo duindorpteneu/platform --env staging
gh secret set SENDGRID_ADMIN_API_KEY --repo duindorpteneu/platform --env staging
gh secret set MOLLIE_API_KEY --repo duindorpteneu/platform --env production
gh secret set SENDGRID_API_KEY --repo duindorpteneu/platform --env production
gh secret set OPERATIONS_HEARTBEAT_URL --repo duindorpteneu/platform --env staging
gh secret set OPERATIONS_HEARTBEAT_URL --repo duindorpteneu/platform --env production
gh secret set IMPORT_STAGING_ENCRYPTION_KEY --repo duindorpteneu/platform --env staging
gh secret set IMPORT_STAGING_ENCRYPTION_KEY --repo duindorpteneu/platform --env production
gh secret set QR_TOKEN_PEPPER --repo duindorpteneu/platform --env staging
gh secret set QR_TOKEN_PEPPER --repo duindorpteneu/platform --env production
gh secret set STAGING_CLEANUP_BACKUP_PASSPHRASE --repo duindorpteneu/platform --env staging
gh secret set PRODUCTION_BACKUP_PASSPHRASE --repo duindorpteneu/platform --env production
gh secret set MOLLIE_PROFILE_ID --repo duindorpteneu/platform --env staging
gh secret set MOLLIE_PROFILE_ID --repo duindorpteneu/platform --env production
```

Niet-geheime configuratie wordt pas na controle gezet met:

```bash
gh variable set IMPORT_RAW_RETENTION_HOURS --repo duindorpteneu/platform --env staging
gh variable set IMPORT_RAW_RETENTION_HOURS --repo duindorpteneu/platform --env production
gh variable set QR_TOKEN_PEPPER_VERSION --repo duindorpteneu/platform --env staging
gh variable set QR_TOKEN_PEPPER_VERSION --repo duindorpteneu/platform --env production
gh variable set SENDGRID_FROM_NAME --body 'Kledingcommissie Duindorp SV' --repo duindorpteneu/platform --env staging
gh variable set SENDGRID_FROM_EMAIL --body 'kleding@duindorpsv.nl' --repo duindorpteneu/platform --env staging
gh variable set SENDGRID_REPLY_TO_EMAIL --body 'kleding@duindorpsv.nl' --repo duindorpteneu/platform --env staging
gh variable set SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT --repo duindorpteneu/platform --env staging
```

SSH-host/user/port/key, `known_hosts`, een externe registry en Tailscale zijn
voor deze releaseketen niet van toepassing. De gesigneerde artifactdownload
vindt op de environment-eigen self-hosted runner plaats; de code verwacht geen
van deze namen.

Laat `DYNAMIC_IMPORT_ENABLED` in beide omgevingen weg of expliciet `false` totdat de unieke key is gezet, cleanup/health groen zijn en de databaseflag `dynamic_import_v2` gecontroleerd kan worden geactiveerd. Iedere deploy vergelijkt vóór appactivatie een niet-geheime keyfingerprint met actieve uploadstaging. Sleutelrotatie of keyverwijdering wordt technisch geblokkeerd totdat `pending=0`; volg de pauze-/retentieprocedure in het operationsrunbook.

Supabase Auth URL Configuration is geen GitHub-secret maar wel een harde externe configuratiebinding. Gebruik per project de eigen origin als Site URL en voeg exact `/staff/set-password` en `/staff/reset-password` op diezelfde origin aan Redirect URLs toe. Gebruik geen wildcard tussen staging en production. De applicatie stuurt nieuwe herstelverzoeken expliciet naar `/staff/reset-password` en vangt uitsluitend een strikt geldig Supabase `type=recovery`-fragment op wanneer de dashboardfallback eerst naar de Site URL gaat.

`SUPABASE_ACCESS_TOKEN`, Resend-, NIKKI- en `MOLLIE_WEBHOOK_SECRET`-waarden worden niet gebruikt en horen daarom niet in dit contract. `PARENT_TOKEN_PEPPER` en de QR-keyring zijn gescheiden cryptografische domeinen. Secretwaarden verschijnen nooit in logs, manifests of documentatie.
