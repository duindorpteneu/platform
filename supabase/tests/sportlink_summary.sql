begin;

create extension if not exists pgtap with schema extensions;
select plan(4);

insert into app.staff_profiles(auth_user_id, display_name, role)
values
  (
    '80000000-0000-4000-8000-000000000001',
    'Import commissie',
    'kledingcommissie'
  ),
  (
    '80000000-0000-4000-8000-000000000002',
    'Import uitgifte',
    'uitgifte'
  );

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"80000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select app.get_sportlink_import_summary(
    '[{"relation_number":"IMP-001"}]'::jsonb
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 verneemt de status van het oude importpad niet'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"80000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_sportlink_import_summary(
    '[{"relation_number":"IMP-001"}]'::jsonb
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte verneemt de status van het oude importpad niet'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"80000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_sportlink_import_summary(
    '[{"relation_number":"IMP-001"}]'::jsonb
  )$$,
  '55000',
  'LEGACY_IMPORT_DISABLED',
  'geautoriseerde commissie kan het oude previewpad niet heropenen'
);
select throws_ok(
  $$select app.commit_sportlink_import(
    'legacy.csv',
    repeat('b', 64),
    '{}'::jsonb,
    '[{"relation_number":"IMP-001"}]'::jsonb
  )$$,
  '55000',
  'LEGACY_IMPORT_DISABLED',
  'geautoriseerde commissie kan het oude commitpad niet heropenen'
);

select * from finish();
rollback;
