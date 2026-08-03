# GitHub environments

Audit opnieuw uitgevoerd op 2026-08-03 via `gh` zonder secretwaarden uit te lezen. Environment branch policies laten uitsluitend `main` toe. Production vereist goedkeuring door `TIXOCEO`; self-review blijft voorlopig toegestaan omdat slechts één revieweraccount beschikbaar is.

## Variables

| Naam | Staging aanwezig | Production aanwezig | Validatie | Gebruikt door | Status/actie |
| --- | --- | --- | --- | --- | --- |
| `APP_HOST` | ja | ja | Exact eigen host | preflight, smokechecks | Stagingtypefout `dstaging-…` gecorrigeerd naar `staging-…` |
| `APP_BIND_PORT` | ja | ja | Exact 14000 / 24000 | Compose | correct |
| `NEXT_PUBLIC_APP_URL` | ja | ja | `https://` + `APP_HOST` | redirects, QR, callbacks, e-mail | correct |
| `SUPABASE_PROJECT_REF` | ja | ja | 20 lowercase tekens; verschillend | DB-/URL-koppeling | correct en verschillend |
| `NEXT_PUBLIC_SUPABASE_URL` | ja | ja | Exact `https://<ref>.supabase.co` | app/runtime | correct |
| `SUPABASE_JWKS` | ja | ja | Compacte publieke ES256/P-256 JWKS van exact het eigen project | lokale staff-JWT-verificatie | bij signing-keyrotatie vóór activatie actualiseren |
| `MOLLIE_ENABLED` | `true` | nee | `false` of `true` | providergate | alleen staging testmode; production default `false` |
| `MOLLIE_PROFILE_ID` | nee | nee | exact verwacht `pfl_…` testprofiel | muterende stagingacceptatie | vóór de Mollie-run als stagingvariable toevoegen; geen productionwaarde nodig zolang production uit staat |
| `EMAIL_ENABLED` | nee | nee | `false` of `true` | providergate | optioneel; default `false` in workflow |
| `DYNAMIC_IMPORT_ENABLED` | nee | nee | `false` of `true` | dynamische-importgate | workflowdefault `false`; pas na sleutel- en retentiecontrole activeren |
| `IMPORT_RAW_RETENTION_HOURS` | nee | nee | geheel getal 1–72 | raw-importretentie | workflowdefault `24` |
| `QR_TOKEN_PEPPER_VERSION` | nee | nee | geheel getal 1–9999 | actuele QR-keyversie | verplicht vóór stagingdeploy; huidige ontbrekende naam blokkeert |
| `QR_TOKEN_PREVIOUS_PEPPER_VERSION` | nee | nee | geheel getal 1–9999, anders dan current | tijdelijk rotatievenster | alleen samen met previous pepper |
| `SENDGRID_FROM_EMAIL` | oude waarde | oude waarde | exact `kleding@duindorpsv.nl`, geverifieerd | SendGrid | door eigenaar gewijzigd; environment bijwerken vóór mailacceptatie |
| `SENDGRID_API_BASE_URL` | EU | EU | `https://api.eu.sendgrid.com` | SendGrid | expliciete EU-regional subuser |
| `SENDGRID_REPLY_TO_EMAIL` | oude waarde | oude waarde | exact `kleding@duindorpsv.nl` | SendGrid | door eigenaar gewijzigd; environment bijwerken vóór mailacceptatie |
| `SENDGRID_WEBHOOK_ID` | `fd290462-…` | `84500cb8-…` | UUID, omgevingsuniek | provider-smoke | production blijft ongevalideerd en uit |
| `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY` | ja | nee | geldige P-256 public key | webhookvalidatie | staging via de exacte signed-webhookconfiguratie opgehaald; production blijft uit |

## Secrets

| Naam | Staging aanwezig | Production aanwezig | Validatie | Gebruikt door | Status |
| --- | --- | --- | --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | ja | ja | JWT, rol `anon`, exact eigen project-ref | publieke runtimebootstrap | aanwezig |
| `SUPABASE_SERVICE_ROLE_KEY` | ja | ja | JWT, rol `service_role`, exact eigen project-ref | serverdata | aanwezig |
| `SUPABASE_DB_URL` | ja | ja | Exact eigen directe Supabase-host of pooler-user; TLS niet uitgeschakeld | migrations | aanwezig |
| `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | ja | ja | base64, exact 32 bytes | Next Server Actions | aanwezig |
| `PARENT_TOKEN_PEPPER` | ja | ja | uniek, minimaal 32 tekens | OTP en oudersessies | aanwezig |
| `QR_TOKEN_PEPPER` | nee | nee | 32 random bytes, canoniek 43 tekens base64url | huidige QR-locator/grantkey | verplicht vóór stagingdeploy; ontbreekt |
| `QR_TOKEN_PREVIOUS_PEPPER` | nee | nee | andere canonieke 32-byte base64url-key | tijdelijk rotatievenster | optioneel en alleen samen met previous versie |
| `CRON_SECRET` | ja | ja | uniek, minimaal 16 tekens | interne jobs | aanwezig |
| `IMPORT_STAGING_ENCRYPTION_KEY` | nee | nee | 32 random bytes, canoniek 43 tekens base64url zonder padding | AES-256-GCM raw-importstaging | vóór importactivering uniek per omgeving toevoegen; niet hergebruiken |
| `OPERATIONS_HEARTBEAT_URL` | nee | nee | geheime `https://` dead-man-switch-URL zonder URL-userinfo | onafhankelijke schedulerbewaking | verplicht voor productiondeploy; staging optioneel maar aanbevolen |
| `MOLLIE_API_KEY` | ja | ja | staging `test_`; production `live_` bij activering | betalingen | aanwezig; providerflag blijft standaard uit |
| `SENDGRID_API_KEY` | ja | ja | `SG.`-vorm | e-mail | aanwezig; providerflag blijft standaard uit |
| `SENDGRID_SMOKE_RECIPIENT` | ja | nee | `info@dgwebservices.nl`, beheerde test-inbox | provider-smoke | uitsluitend gebruikt door de handmatige staging-smoke |

Bij toekomstige rotatie of provideractivering worden secrets uitsluitend interactief gezet (gebruik geen `--body`):

```bash
gh secret set MOLLIE_API_KEY --repo duindorpteneu/platform --env staging
gh secret set SENDGRID_API_KEY --repo duindorpteneu/platform --env staging
gh secret set MOLLIE_API_KEY --repo duindorpteneu/platform --env production
gh secret set SENDGRID_API_KEY --repo duindorpteneu/platform --env production
gh secret set OPERATIONS_HEARTBEAT_URL --repo duindorpteneu/platform --env staging
gh secret set OPERATIONS_HEARTBEAT_URL --repo duindorpteneu/platform --env production
gh secret set IMPORT_STAGING_ENCRYPTION_KEY --repo duindorpteneu/platform --env staging
gh secret set IMPORT_STAGING_ENCRYPTION_KEY --repo duindorpteneu/platform --env production
gh secret set QR_TOKEN_PEPPER --repo duindorpteneu/platform --env staging
gh secret set QR_TOKEN_PEPPER --repo duindorpteneu/platform --env production
```

De niet-geheime Mollie-profielbinding wordt na controle van het bedoelde testprofiel gezet met:

```bash
gh variable set MOLLIE_PROFILE_ID --repo duindorpteneu/platform --env staging
gh variable set IMPORT_RAW_RETENTION_HOURS --repo duindorpteneu/platform --env staging
gh variable set IMPORT_RAW_RETENTION_HOURS --repo duindorpteneu/platform --env production
gh variable set QR_TOKEN_PEPPER_VERSION --repo duindorpteneu/platform --env staging
gh variable set QR_TOKEN_PEPPER_VERSION --repo duindorpteneu/platform --env production
gh variable set SENDGRID_FROM_EMAIL --body 'kleding@duindorpsv.nl' --repo duindorpteneu/platform --env staging
gh variable set SENDGRID_REPLY_TO_EMAIL --body 'kleding@duindorpsv.nl' --repo duindorpteneu/platform --env staging
```

Laat `DYNAMIC_IMPORT_ENABLED` in beide omgevingen weg of expliciet `false` totdat de unieke key is gezet, cleanup/health groen zijn en de databaseflag `dynamic_import_v2` gecontroleerd kan worden geactiveerd. Iedere deploy vergelijkt vóór appactivatie een niet-geheime keyfingerprint met actieve uploadstaging. Sleutelrotatie of keyverwijdering wordt technisch geblokkeerd totdat `pending=0`; volg de pauze-/retentieprocedure in het operationsrunbook.

`SUPABASE_ACCESS_TOKEN`, Resend-, NIKKI- en `MOLLIE_WEBHOOK_SECRET`-waarden worden niet gebruikt en horen daarom niet in dit contract. `PARENT_TOKEN_PEPPER` en de QR-keyring zijn gescheiden cryptografische domeinen. Secretwaarden verschijnen nooit in logs, manifests of documentatie.
