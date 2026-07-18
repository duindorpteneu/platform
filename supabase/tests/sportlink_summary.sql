begin;

create extension if not exists pgtap with schema extensions;
select plan(10);

insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('80000000-0000-4000-8000-000000000001', 'Import commissie', 'kledingcommissie'),
  ('80000000-0000-4000-8000-000000000002', 'Import uitgifte', 'uitgifte');
insert into app.members (relation_number, first_name, last_name, email, team, active_for_season)
values
  ('IMP-001', 'Sophie', 'Tester', 'sophie-import@example.invalid', 'JO11-1', true),
  ('IMP-002', 'Yassin', 'Tester', 'yassin-import@example.invalid', 'JO13-1', true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"80000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok(
  $$select app.get_sportlink_import_summary('[{"relation_number":"IMP-001"}]'::jsonb)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan importwijzigingen niet voorvertonen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"80000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select app.get_sportlink_import_summary('[{"relation_number":"IMP-001"}]'::jsonb)$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan importwijzigingen niet voorvertonen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"80000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;

create temporary table import_result as
select app.get_sportlink_import_summary('[
  {"relation_number":"imp-001","first_name":"Sophie","insertion":null,"last_name":"Tester","email":"SOPHIE-IMPORT@EXAMPLE.INVALID","team":"JO11-1","active_for_season":true},
  {"relation_number":"IMP-002","first_name":"Yassin","insertion":null,"last_name":"Tester","email":"yassin-import@example.invalid","team":"JO13-2","active_for_season":true},
  {"relation_number":"IMP-003","first_name":"Noa","insertion":null,"last_name":"Nieuw","email":"noa-import@example.invalid","team":"MO15-1","active_for_season":true}
]'::jsonb) as summary;

select is((summary #>> '{total}')::integer, 3, 'preview telt alle geldige rijen') from import_result;
select is((summary #>> '{new}')::integer, 1, 'preview telt nieuwe leden') from import_result;
select is((summary #>> '{updated}')::integer, 1, 'preview telt gewijzigde leden') from import_result;
select is((summary #>> '{unchanged}')::integer, 1, 'preview telt ongewijzigde leden') from import_result;

create temporary table committed_result as
select app.commit_sportlink_import(
  'sportlink-test.csv',
  repeat('b', 64),
  '{"delimiter":";","columns":{"relationNumber":"Relatienummer"}}'::jsonb,
  '[
    {"relation_number":"imp-001","first_name":"Sophie","insertion":null,"last_name":"Tester","email":"SOPHIE-IMPORT@EXAMPLE.INVALID","team":"JO11-1","active_for_season":true},
    {"relation_number":"IMP-002","first_name":"Yassin","insertion":null,"last_name":"Tester","email":"yassin-import@example.invalid","team":"JO13-2","active_for_season":true},
    {"relation_number":"IMP-003","first_name":"Noa","insertion":null,"last_name":"Nieuw","email":"noa-import@example.invalid","team":"MO15-1","active_for_season":true}
  ]'::jsonb
) as result;

select is((result #>> '{upserted}')::integer, 3, 'commit verwerkt alle geldige rijen') from committed_result;
select is((select row_counts #>> '{updated}' from app.import_batches where file_name = 'sportlink-test.csv'), '1', 'batch bewaart wijzigingssamenvatting');
select is((select mapping #>> '{columns,relationNumber}' from app.import_batches where file_name = 'sportlink-test.csv'), 'Relatienummer', 'batch bewaart kolomkoppeling');
select is((select team from app.members where relation_number = 'IMP-002'), 'JO13-2', 'commit werkt bestaand lid transactioneel bij');

select * from finish();
rollback;
