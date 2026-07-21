begin;

create extension if not exists pgtap with schema extensions;
select plan(11);

insert into app.staff_profiles(auth_user_id, display_name, role, active)
values ('f5000000-0000-4000-8000-000000000001', 'Staff sessietest', 'beheerder', true);

select ok(
  not has_function_privilege('anon', 'app.create_staff_session_exchange()', 'execute'),
  'anon kan geen staff-exchange maken'
);
select ok(
  has_function_privilege('authenticated', 'app.create_staff_session_exchange()', 'execute'),
  'authenticated mag na AAL2 een staff-exchange maken'
);
select ok(
  not has_function_privilege('authenticated', 'app.consume_staff_session_exchange(text)', 'execute'),
  'authenticated kan een exchange niet zelf consumeren'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f5000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok(
  $$select app.create_staff_session_exchange()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan geen staff-exchange maken'
);

select set_config('request.jwt.claims', '{"sub":"f5000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
create temp table exchange_result as select app.create_staff_session_exchange() as payload;
select ok((payload->>'exchangeToken') ~ '^[0-9a-f]{64}$', 'AAL2 ontvangt een 256-bit eenmalige exchange')
from exchange_result;

reset role;
create temp table session_result as
select app.consume_staff_session_exchange((select payload->>'exchangeToken' from exchange_result)) as payload;

select is(payload #>> '{context,role}', 'beheerder', 'exchange wordt aan het actieve staff-profiel gekoppeld')
from session_result;
select ok((payload->>'sessionToken') ~ '^[0-9a-f]{64}$', 'consumptie levert een opaque 256-bit staff-sessie')
from session_result;
select throws_ok(
  $$select app.consume_staff_session_exchange((select payload->>'exchangeToken' from exchange_result))$$,
  '22023',
  'STAFF_SESSION_EXCHANGE_INVALID',
  'een exchange is strikt single-use'
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

select * from finish();
rollback;
