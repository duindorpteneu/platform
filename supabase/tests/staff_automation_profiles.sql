begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(
  auth_user_id, display_name, role, active
) values (
  'a1300000-0000-4000-8000-000000000001',
  'Menselijke beheerder',
  'beheerder',
  true
);

select set_config('app.staff_automation_internal', 'on', true);
insert into app.staff_profiles(
  auth_user_id,
  display_name,
  role,
  active,
  automation_kind
) values (
  'a1300000-0000-4000-8000-000000000002',
  'Staging SendGrid-acceptatie',
  'beheerder',
  false,
  'sendgrid_acceptance'
);
select set_config('app.staff_automation_internal', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"a1300000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

select is(
  jsonb_array_length(app.get_settings_workspace_v3()->'staff'),
  1,
  'de personeelsworkspace verbergt niet-persoonsgebonden automation actors'
);

select is(
  app.get_settings_workspace_v3()
    #>> '{staff,0,displayName}',
  'Menselijke beheerder',
  'de menselijke beheerder blijft zichtbaar en beheerbaar'
);

select is(
  jsonb_array_length(app.get_settings_workspace_v2()->'staff'),
  1,
  'de ondersteunde legacy-v2-projectie lekt geen automation actor'
);

select is(
  jsonb_array_length(app.get_settings_workspace()->'staff'),
  1,
  'de ondersteunde legacy-v1-projectie lekt geen automation actor'
);

select is(
  (select count(*)::integer from app.staff_profiles),
  1,
  'RLS verbergt automation actors ook bij directe tabelselectie'
);

select throws_ok(
  $$select app.update_staff_profile(
      'a1300000-0000-4000-8000-000000000002',
      'Gemanipuleerde automation',
      'kledingcommissie',
      true,
      null
    )$$,
  '23514',
  'STAFF_AUTOMATION_PROFILE_MANAGED_INTERNALLY',
  'de gewone beheerworkflow kan automation actors niet muteren'
);

select is(
  has_function_privilege(
    'authenticated',
    'app.settings_workspace_legacy_raw_20260813()',
    'EXECUTE'
  ),
  false,
  'de onbewerkte legacy-projectie is niet API-uitvoerbaar'
);

reset role;

select set_config('app.staff_automation_internal', 'on', true);
select throws_ok(
  $$insert into app.staff_profiles(
      auth_user_id, display_name, role, automation_kind
    ) values (
      'a1300000-0000-4000-8000-000000000003',
      'Onbekende automation',
      'beheerder',
      'unknown'
    )$$,
  '23514',
  null,
  'onbekende automationsoorten zijn databasebreed geblokkeerd'
);
select set_config('app.staff_automation_internal', 'off', true);

select * from finish();
rollback;
