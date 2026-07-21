begin;

create extension if not exists pgtap with schema extensions;
select plan(15);

insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('10000000-0000-4000-8000-000000000001', 'Test uitgifte', 'uitgifte'),
  ('10000000-0000-4000-8000-000000000002', 'Test commissie', 'kledingcommissie');

insert into app.import_batches (file_name, checksum, actor_user_id, status)
values ('rls-test.csv', repeat('a', 64), '10000000-0000-4000-8000-000000000002', 'committed');

insert into app.members (relation_number, first_name, last_name, email, team)
values ('RLS-001', 'Test', 'Lid', 'rls-lid@example.invalid', 'Testteam');

select ok(
  has_function_privilege('authenticated', 'app.get_staff_auth_context()', 'execute'),
  'authenticated mag het afgeschermde staff-authcontract aanroepen'
);
select ok(
  not has_function_privilege('anon', 'app.get_staff_auth_context()', 'execute'),
  'anon kan het staff-authcontract niet aanroepen'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000001","aal":"aal2"}', true);

select is((select count(*) from app.members where relation_number = 'RLS-001'), 0::bigint, 'uitgifte kan leden niet rechtstreeks doorzoeken');
select is((select count(*) from app.import_batches where file_name = 'rls-test.csv'), 0::bigint, 'uitgifte kan imports niet lezen');
select is((select count(*) from app.staff_profiles), 1::bigint, 'uitgifte ziet alleen het eigen staff-profiel');
select is(app.get_staff_auth_context()->>'userId', '10000000-0000-4000-8000-000000000001', 'staff-authcontext gebruikt uitsluitend auth.uid()');
select is(app.get_staff_auth_context()->>'role', 'uitgifte', 'staff-authcontext levert de actieve canonieke rol');
select throws_ok(
  $$select app.register_delivery_receipt(current_date, 'Niet toegestaan', null, '[{"variant_id":"20000000-0000-4000-8000-000000000001","quantity":1}]'::jsonb)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan geen voorraadontvangst registreren'
);
select is(app.lookup_fulfilment(repeat('f', 64))->>'status', 'invalid', 'uitgifte mag alleen via de minimale QR-lookup zoeken');
select throws_ok(
  $$select app.get_stock_overview(null)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan het operationele voorraadoverzicht niet openen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000002","aal":"aal1"}', true);
set local role authenticated;
select throws_ok(
  $$select app.get_stock_overview(null)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'een geldige medewerker zonder AAL2 kan geen staff-RPC openen'
);
select throws_ok(
  $$select app.get_staff_auth_context()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'staff-authcontext weigert een AAL1-token'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;

select is((select count(*) from app.members where relation_number = 'RLS-001'), 1::bigint, 'kledingcommissie kan leden operationeel lezen');
select is((select count(*) from app.import_batches where file_name = 'rls-test.csv'), 1::bigint, 'kledingcommissie kan imports lezen');
select lives_ok(
  $$select app.get_stock_overview(null)$$,
  'kledingcommissie kan het operationele voorraadoverzicht openen'
);

select * from finish();
rollback;
