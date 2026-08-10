# Eerste stagingbeheerder

De applicatie heeft geen rol `owner`. De eigenaar van de stagingomgeving krijgt de canonieke rol `beheerder`. Gebruik een persoonlijk account; maak geen gedeeld clubaccount en stuur wachtwoord of MFA-QR nooit via chat.

## Eenmalige bootstrap

1. Open Supabase-project `dxbdjtbyghsovlrdcwcr` en kies **Authentication → Users → Add user → Create new user**. Gebruik het persoonlijke staging-e-mailadres, een uniek wachtwoord van minimaal 16 tekens en bevestig het e-mailadres. Gebruik voor de eerste beheerder niet **Send invitation**: er bestaat dan nog geen beheerder die het profiel auditbaar kan registreren.
2. Open de SQL Editor van hetzelfde stagingproject, vervang uitsluitend de twee hoofdletterplaceholders en voer dit blok uit:

```sql
do $$
declare
  v_email text := lower(trim('OWNER_EMAIL_HIER'));
  v_user_id uuid;
  v_profile_id uuid;
begin
  if exists (select 1 from app.staff_profiles where active and role = 'beheerder') then
    raise exception 'ACTIVE_ADMIN_ALREADY_EXISTS';
  end if;

  select id into strict v_user_id
  from auth.users
  where lower(email) = v_email;

  insert into app.staff_profiles(auth_user_id, display_name, role, active)
  values (v_user_id, trim('WEERGAVENAAM_HIER'), 'beheerder', true)
  returning id into v_profile_id;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'staff.bootstrap.created',
    'staff_profile',
    v_profile_id,
    jsonb_build_object('role', 'beheerder', 'environment', 'staging')
  );
end $$;
```

3. Controleer zonder gegevens te kopiëren naar een ticket of chat:

```sql
select
  profile.auth_user_id,
  profile.display_name,
  profile.role,
  profile.active,
  auth_user.email_confirmed_at is not null as email_confirmed
from app.staff_profiles profile
join auth.users auth_user on auth_user.id = profile.auth_user_id
where profile.role = 'beheerder';
```

4. Log in op `https://staging-duindorp.dgwebservices.nl/staff/login`. De applicatie stuurt de eerste AAL1-sessie naar `/staff/mfa`; koppel daar TOTP en bevestig de zescijferige code. Backoffice-toegang wordt pas op AAL2 verleend.

## Volgende medewerkers

Na deze bootstrap gebruikt de beheerder **Backoffice → Instellingen → Medewerker uitnodigen**. De uitnodigingslink komt via Supabase Auth binnen op `/staff/set-password`. De invite-sessie wordt uit het URL-fragment gelezen en direct uit de adresbalk gewist; daarna stelt de medewerker een wachtwoord van minimaal 16 tekens in en volgt de verplichte TOTP-koppeling. Rollen blijven beperkt tot `beheerder`, `kledingcommissie` en `uitgifte`.

## Wachtwoord herstellen

Configureer in het staging-Supabaseproject onder **Authentication → URL Configuration**:

- Site URL: `https://staging-duindorp.dgwebservices.nl`;
- Redirect URL: `https://staging-duindorp.dgwebservices.nl/staff/set-password`;
- Redirect URL: `https://staging-duindorp.dgwebservices.nl/staff/reset-password`.

Een medewerker gebruikt daarna **Medewerkerslogin → Wachtwoord vergeten?**. Het antwoord blijft voor bekende en onbekende adressen gelijk. Een bestaande geverifieerde TOTP-factor wordt vóór de wachtwoordwijziging opnieuw gevraagd; na succes worden alle opaque app-sessies, open sessie-exchanges en sessiegebonden QR-scangrants ingetrokken en moet de medewerker opnieuw inloggen. De Supabase-dashboardactie **Send password recovery** blijft als operationele fallback bruikbaar: een strikt geldig `type=recovery`-fragment wordt vanaf de Site URL direct naar dezelfde staff-resetpagina geleid.

Voor het E2E-account blijft de bestaande TOTP-seed gelijk. Werk na herstel uitsluitend de GitHub Environment-secret `E2E_ADMIN_PASSWORD` bij naar het exact gekozen wachtwoord; wijzig `E2E_ADMIN_TOTP_SECRET` alleen wanneer de factor bewust opnieuw is gekoppeld. Plaats geen van beide waarden in chat, logs of workflowinputs.
