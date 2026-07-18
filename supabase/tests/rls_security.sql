begin;

create extension if not exists pgtap with schema extensions;
select plan(7);

insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('10000000-0000-4000-8000-000000000001', 'Test uitgifte', 'uitgifte'),
  ('10000000-0000-4000-8000-000000000002', 'Test commissie', 'kledingcommissie');

insert into app.import_batches (file_name, checksum, actor_user_id, status)
values ('rls-test.csv', repeat('a', 64), '10000000-0000-4000-8000-000000000002', 'committed');

insert into app.members (relation_number, first_name, last_name, email, team)
values ('RLS-001', 'Test', 'Lid', 'rls-lid@example.invalid', 'Testteam');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);

select is((select count(*) from app.members where relation_number = 'RLS-001'), 0::bigint, 'uitgifte kan leden niet rechtstreeks doorzoeken');
select is((select count(*) from app.import_batches where file_name = 'rls-test.csv'), 0::bigint, 'uitgifte kan imports niet lezen');
select is((select count(*) from app.staff_profiles), 1::bigint, 'uitgifte ziet alleen het eigen staff-profiel');
select throws_ok(
  $$select app.register_delivery_receipt(current_date, 'Niet toegestaan', null, '[{"variant_id":"20000000-0000-4000-8000-000000000001","quantity":1}]'::jsonb)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan geen voorraadontvangst registreren'
);
select is(app.lookup_fulfilment(repeat('f', 64))->>'status', 'invalid', 'uitgifte mag alleen via de minimale QR-lookup zoeken');

reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
set local role authenticated;

select is((select count(*) from app.members where relation_number = 'RLS-001'), 1::bigint, 'kledingcommissie kan leden operationeel lezen');
select is((select count(*) from app.import_batches where file_name = 'rls-test.csv'), 1::bigint, 'kledingcommissie kan imports lezen');

select * from finish();
rollback;
