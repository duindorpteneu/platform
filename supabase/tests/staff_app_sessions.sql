begin;

create extension if not exists pgtap with schema extensions;
select plan(18);

insert into app.staff_profiles(auth_user_id, display_name, role, active)
values ('f5000000-0000-4000-8000-000000000001', 'Staff sessietest', 'beheerder', true);

select ok(
  not has_function_privilege('anon', 'app.create_staff_session_exchange()', 'execute'),
  'anon kan geen staff-exchange maken'
);
select ok(
  not has_function_privilege('authenticated', 'app.create_staff_session_exchange()', 'execute'),
  'de onbetrouwbare browser-PostgREST exchange is ingetrokken'
);
select ok(
  not has_function_privilege('authenticated', 'app.create_staff_app_session_for_user(uuid)', 'execute'),
  'authenticated kan geen app-sessie voor een user-id maken'
);
select ok(
  has_function_privilege('service_role', 'app.create_staff_app_session_for_user(uuid)', 'execute'),
  'alleen service_role kan na cryptografische tokenverificatie een app-sessie maken'
);
select ok(
  not has_function_privilege('anon', 'app.revoke_all_staff_app_sessions_for_user(uuid)', 'execute'),
  'anon kan geen sessies na wachtwoordherstel intrekken'
);
select ok(
  not has_function_privilege('authenticated', 'app.revoke_all_staff_app_sessions_for_user(uuid)', 'execute'),
  'een browser-JWT kan geen sessies na wachtwoordherstel intrekken'
);
select ok(
  has_function_privilege('service_role', 'app.revoke_all_staff_app_sessions_for_user(uuid)', 'execute'),
  'alleen service_role kan het server-side herstel afronden'
);

create temp table session_result as
select app.create_staff_app_session_for_user('f5000000-0000-4000-8000-000000000001') as payload;

select is(payload #>> '{context,role}', 'beheerder', 'sessie wordt aan het actieve staff-profiel gekoppeld')
from session_result;
select ok((payload->>'sessionToken') ~ '^[0-9a-f]{64}$', 'de service ontvangt een opaque 256-bit staff-sessie')
from session_result;
select throws_ok(
  $$select app.create_staff_app_session_for_user(null)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'een ontbrekende geverifieerde user-id faalt gesloten'
);
select is(
  app.get_staff_app_session((select payload->>'sessionToken' from session_result))->>'role',
  'beheerder',
  'een geldige opaque sessie levert de actuele rol'
);
select is(
  app.revoke_staff_app_session((select payload->>'sessionToken' from session_result)),
  1,
  'staff-sessie kan server-side worden ingetrokken'
);
select ok(
  app.get_staff_app_session((select payload->>'sessionToken' from session_result)) is null,
  'ingetrokken staff-sessie faalt gesloten'
);

create temp table recovery_session_result as
select app.create_staff_app_session_for_user('f5000000-0000-4000-8000-000000000001') as payload;
insert into private.staff_session_exchanges(token_hash, auth_user_id, expires_at)
values(
  repeat('d', 64),
  'f5000000-0000-4000-8000-000000000001',
  timezone('utc', now()) + interval '2 minutes'
);
create temp table recovery_result as
select app.revoke_all_staff_app_sessions_for_user('f5000000-0000-4000-8000-000000000001') as payload;
select is(
  (payload->>'sessionsRevoked')::integer,
  1,
  'wachtwoordherstel trekt alle actieve opaque appsessies in'
) from recovery_result;
select is(
  (payload->>'exchangesConsumed')::integer,
  1,
  'wachtwoordherstel maakt open sessie-exchanges onbruikbaar'
) from recovery_result;
select ok(
  app.get_staff_app_session((select payload->>'sessionToken' from recovery_session_result)) is null,
  'een vóór herstel uitgegeven appsessie faalt daarna direct gesloten'
);
select ok(
  exists(
    select 1
    from app.audit_logs audit
    where audit.actor_user_id = 'f5000000-0000-4000-8000-000000000001'
      and audit.action = 'staff.password.recovery.completed'
      and not (audit.metadata ?| array['email', 'password', 'token'])
  ),
  'herstel wordt zonder credentials of e-mailadres geaudit'
);

update app.staff_profiles set active = false where auth_user_id = 'f5000000-0000-4000-8000-000000000001';
select throws_ok(
  $$select app.create_staff_app_session_for_user('f5000000-0000-4000-8000-000000000001')$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'een inactief staffprofiel kan geen nieuwe app-sessie krijgen'
);

select * from finish();
rollback;
