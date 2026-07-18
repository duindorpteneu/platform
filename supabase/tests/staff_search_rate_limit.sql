begin;
select plan(5);

insert into app.staff_profiles(auth_user_id, display_name, role, active) values
  ('f2000000-0000-4000-8000-000000000001', 'Zoek Beheerder', 'beheerder', true),
  ('f2000000-0000-4000-8000-000000000002', 'Zoek Uitgifte', 'uitgifte', true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select lives_ok($$select app.consume_staff_search_rate()$$, 'AAL2-beheerder kan de zoeklimiet gebruiken');
select is(app.consume_staff_search_rate(), true, 'een normale zoekactie wordt toegestaan');
select is(
  (select bool_and(app.consume_staff_search_rate()) from generate_series(1, 118)),
  true,
  'de resterende acties binnen het venster worden toegestaan'
);
select is(app.consume_staff_search_rate(), false, 'actie boven de limiet wordt geblokkeerd');

select set_config('request.jwt.claims', '{"sub":"f2000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok(
  $$select app.consume_staff_search_rate()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifterol kan de ledenzoekfunctie niet forceren'
);

select * from finish();
rollback;
