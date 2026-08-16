begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('a1600000-0000-4000-8000-000000000001', 'Handmatig beheer', 'beheerder'),
  ('a1600000-0000-4000-8000-000000000002', 'Handmatig commissie', 'kledingcommissie');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('a1610000-0000-4000-8000-000000000001', '2050/2051 handmatig', 10000, 'open');
update app.app_settings
set active_season_id = 'a1610000-0000-4000-8000-000000000001'
where id = true;

select ok(
  (
    select is_nullable = 'YES'
    from information_schema.columns
    where table_schema = 'app' and table_name = 'members' and column_name = 'team'
  ),
  'team is optioneel voor import en handmatige invoer'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'private.dynamic_import_mapping_preferences',
    'SELECT'
  ),
  'importvoorkeuren zijn niet rechtstreeks uitleesbaar'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.filter_dynamic_import_optional_conflicts(uuid,uuid,integer,jsonb)',
    'EXECUTE'
  ),
  'alleen de service-role kan geselecteerde importrijen filteren'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1600000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.preflight_manual_member_create(
    null, 'Noa', null, 'Jansen', null, date '2014-01-31'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan geen handmatig lid voorbereiden'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1600000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);

create temporary table manual_preflight as
select app.preflight_manual_member_create(
  'SL-MANUAL-1',
  'Noa',
  null,
  'Jansen',
  'ouder@example.test',
  date '2014-01-31'
) result;
select is(
  jsonb_array_length((select result->'candidates' from manual_preflight)),
  0,
  'nieuw handmatig lid heeft geen kandidaat'
);

create temporary table manual_created as
select app.create_manual_member(
  'SL-MANUAL-1',
  'Noa',
  null,
  'Jansen',
  'ouder@example.test',
  date '2014-01-31',
  'female',
  null,
  'a1620000-0000-4000-8000-000000000001',
  (select result->>'fingerprint' from manual_preflight),
  false,
  null
) result;
reset role;

select is(
  (
    select concat_ws(':', member.first_name, member.last_name, member.gender::text)
    from app.members member
    where member.id = (select (result->>'memberId')::uuid from manual_created)
  ),
  'Noa:Jansen:female',
  'handmatig lid wordt met gekozen persoonsgegevens aangemaakt'
);
select is(
  (
    select sensitive.date_of_birth
    from private.member_sensitive_identity sensitive
    where sensitive.member_id = (select (result->>'memberId')::uuid from manual_created)
  ),
  date '2014-01-31',
  'geboortedatum wordt uitsluitend in de private identity opgeslagen'
);
select is(
  (
    select member_season.reconciliation_status::text
    from app.member_seasons member_season
    where member_season.id = (select (result->>'memberSeasonId')::uuid from manual_created)
  ),
  'legacy_unknown',
  'ontbrekend team laat een expliciet onvolledig lid-seizoen toe'
);
select is(
  (
    select count(*)
    from app.member_orders orders
    where orders.member_id = (select (result->>'memberId')::uuid from manual_created)
  ),
  0::bigint,
  'handmatige invoer maakt geen bestelling aan'
);
select is(
  (
    select count(*)
    from private.parent_portal_grants grant_row
    join app.member_seasons member_season on member_season.id = grant_row.member_season_id
    where member_season.member_id = (select (result->>'memberId')::uuid from manual_created)
  ),
  0::bigint,
  'handmatige invoer activeert geen oudertoegang'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1600000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.create_manual_member(
    'SL-MANUAL-1',
    'Noa',
    null,
    'Jansen',
    'ouder@example.test',
    date '2014-01-31',
    'female',
    null,
    'a1620000-0000-4000-8000-000000000001',
    (select result->>'fingerprint' from manual_preflight),
    false,
    null
  )->>'reused',
  'true',
  'dezelfde handmatige request-ID is idempotent'
);

create temporary table duplicate_preflight as
select app.preflight_manual_member_create(
  null,
  'Noa',
  null,
  'Jansen',
  'ouder@example.test',
  date '2014-01-31'
) result;
select is(
  (select result #>> '{candidates,0,reasons,0}' from duplicate_preflight),
  'name_date_of_birth',
  'naam plus DOB wordt als mogelijke dubbel teruggegeven'
);
select throws_ok(
  $$select app.create_manual_member(
    null,
    'Noa',
    null,
    'Jansen',
    'ouder@example.test',
    date '2014-01-31',
    'female',
    'JO14-1',
    'a1620000-0000-4000-8000-000000000002',
    (select result->>'fingerprint' from duplicate_preflight),
    false,
    null
  )$$,
  'P0001',
  'MANUAL_MEMBER_DUPLICATE_CONFIRMATION_REQUIRED',
  'mogelijke dubbel vereist expliciete bevestiging'
);

select lives_ok(
  $$select app.create_manual_member(
    null,
    'Noa',
    null,
    'Jansen',
    'ouder@example.test',
    date '2014-01-31',
    'female',
    'JO14-1',
    'a1620000-0000-4000-8000-000000000003',
    (select result->>'fingerprint' from duplicate_preflight),
    true,
    null
  )$$,
  'beheerder kan na dezelfde preflight bewust een nieuw lid aanmaken'
);

select throws_ok(
  $$select app.create_manual_member(
    'SL-MANUAL-1',
    'Ander',
    null,
    'Lid',
    null,
    null,
    'unknown',
    null,
    'a1620000-0000-4000-8000-000000000004',
    (app.preflight_manual_member_create(
      'SL-MANUAL-1', 'Ander', null, 'Lid', null, null
    )->>'fingerprint'),
    true,
    null
  )$$,
  'P0001',
  'MANUAL_MEMBER_EXTERNAL_ID_EXISTS',
  'een bestaand Sportlink-ID kan nooit worden omzeild'
);

reset role;
select * from finish();
rollback;
