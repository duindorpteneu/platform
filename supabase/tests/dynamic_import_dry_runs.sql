begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('d0000000-0000-4000-8000-000000000001', 'Importbeheer', 'beheerder'),
  ('d0000000-0000-4000-8000-000000000002', 'Importcommissie', 'kledingcommissie'),
  ('d0000000-0000-4000-8000-000000000003', 'Andere beheerder', 'beheerder'),
  ('d0000000-0000-4000-8000-000000000004', 'Importuitgifte', 'uitgifte');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('d1000000-0000-4000-8000-000000000001', '2047/2048 dry-run', 10000, 'open');
update app.app_settings
set active_season_id = 'd1000000-0000-4000-8000-000000000001'
where id = true;
insert into app.articles(id, name, code, active, sort_order) values
  ('d2000000-0000-4000-8000-000000000001', 'Broek', 'BROEK', true, 1);
insert into app.article_variants(
  id, article_id, size, sku, active, sort_order
) values
  (
    'd3000000-0000-4000-8000-000000000001',
    'd2000000-0000-4000-8000-000000000001',
    '152',
    'BR-152',
    true,
    1
  ),
  (
    'd3000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000001',
    '164',
    'BR-164',
    true,
    2
  );
insert into app.article_seasons(article_id, season_id) values(
  'd2000000-0000-4000-8000-000000000001',
  'd1000000-0000-4000-8000-000000000001'
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  active_for_season,
  gender
) values
  (
    'd4000000-0000-4000-8000-000000000001',
    'EX-1',
    'Bestaand',
    'Lid',
    'ouder-bestaand@example.test',
    'JO15-1',
    true,
    'male'
  ),
  (
    'd4000000-0000-4000-8000-000000000002',
    'EX-SKIP',
    'Exact',
    'Ongewijzigd',
    'ouder-exact@example.test',
    'JO12-1',
    true,
    'female'
  ),
  (
    'd4000000-0000-4000-8000-000000000003',
    'EX-UPDATE',
    'Team',
    'Wijziging',
    'ouder-team@example.test',
    'JO10-1',
    true,
    'male'
  ),
  (
    'd4000000-0000-4000-8000-000000000004',
    'EX-PARENT',
    'Eigen',
    'Keuze',
    'ouder-keuze@example.test',
    'JO14-1',
    true,
    'female'
  ),
  (
    'd4000000-0000-4000-8000-000000000005',
    'AMB-1',
    'Dubbel',
    'Profiel',
    'ouder-een@example.test',
    'JO9-1',
    true,
    'male'
  ),
  (
    'd4000000-0000-4000-8000-000000000006',
    'AMB-2',
    'Dubbel',
    'Profiel',
    'ouder-twee@example.test',
    'JO9-1',
    true,
    'male'
  );
update private.member_sensitive_identity sensitive
set date_of_birth = fixture.date_of_birth
from (
  values
    ('d4000000-0000-4000-8000-000000000001'::uuid, date '2012-01-01'),
    ('d4000000-0000-4000-8000-000000000002'::uuid, date '2013-02-02'),
    ('d4000000-0000-4000-8000-000000000003'::uuid, date '2015-03-03'),
    ('d4000000-0000-4000-8000-000000000004'::uuid, date '2011-04-04'),
    ('d4000000-0000-4000-8000-000000000005'::uuid, date '2017-05-05'),
    ('d4000000-0000-4000-8000-000000000006'::uuid, date '2017-05-05')
) fixture(member_id, date_of_birth)
where sensitive.member_id = fixture.member_id;
insert into app.member_article_sizes(
  member_id,
  season_id,
  member_season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  confirmed_at
) values(
  'd4000000-0000-4000-8000-000000000001',
  'd1000000-0000-4000-8000-000000000001',
  (
    select id
    from app.member_seasons
    where member_id = 'd4000000-0000-4000-8000-000000000001'
      and season_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  'd2000000-0000-4000-8000-000000000001',
  'd3000000-0000-4000-8000-000000000001',
  'confirmed',
  'staff',
  timezone('utc', now())
);
insert into private.parent_accounts(id, email_normalized)
values(
  'd6000000-0000-4000-8000-000000000001',
  'ouder-dry-run@example.invalid'
);
insert into app.member_article_sizes(
  member_id,
  season_id,
  member_season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  raw_value,
  member_note,
  confirmed_at,
  confirmed_by_parent_account_id
) values(
  'd4000000-0000-4000-8000-000000000004',
  'd1000000-0000-4000-8000-000000000001',
  (
    select id
    from app.member_seasons
    where member_id = 'd4000000-0000-4000-8000-000000000004'
      and season_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  'd2000000-0000-4000-8000-000000000001',
  null,
  'conflict',
  'parent',
  'Eigen pasvorm',
  'Graag samen met de kledingcommissie meten',
  timezone('utc', now()),
  'd6000000-0000-4000-8000-000000000001'
);
create temporary table skip_member_before as
select
  member.updated_at member_updated_at,
  member.imported_from_batch_id,
  member_season.updated_at member_season_updated_at,
  member_season.source_import_batch_id
from app.members member
join app.member_seasons member_season
  on member_season.member_id = member.id
  and member_season.season_id = 'd1000000-0000-4000-8000-000000000001'
where member.id = 'd4000000-0000-4000-8000-000000000002';

update app.release_feature_flags
set enabled = true
where key = 'dynamic_import_v2';

select has_table('app', 'dynamic_import_runs', 'persistente importruns bestaan');
select has_table(
  'app',
  'dynamic_import_row_results',
  'veilige per-rijresultaten bestaan'
);
select has_table(
  'private',
  'dynamic_import_selected_rows',
  'geselecteerde stagingrijen zijn privé'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'private.dynamic_import_selected_rows',
    'SELECT'
  ),
  'browserrollen kunnen geselecteerde import-PII niet lezen'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'private.dynamic_import_selected_identity_keys',
    'SELECT'
  ),
  'browserrollen kunnen private importidentiteitssleutels niet lezen'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.claim_dynamic_import_run(uuid,integer)',
    'EXECUTE'
  ),
  'de workerclaim is service-only'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.analyze_dynamic_import_chunk(uuid,uuid,integer,integer)',
    'EXECUTE'
  ),
  'de begrensde dry-runanalyse is service-only'
);
select ok(
  not has_table_privilege(
    'anon',
    'app.dynamic_import_runs',
    'SELECT'
  )
  and not has_table_privilege(
    'anon',
    'app.dynamic_import_row_results',
    'SELECT'
  ),
  'anon heeft geen tabelprivilege op importruns of rijresultaten'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.claim_dynamic_import_run(uuid,integer)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.stage_dynamic_import_rows(uuid,uuid,integer,integer,jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.analyze_dynamic_import_chunk(uuid,uuid,integer,integer)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.commit_dynamic_import_chunk(uuid,uuid,integer,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.commit_dynamic_import_chunk(uuid,uuid,integer,integer)',
    'EXECUTE'
  ),
  'alle muterende worker-RPCs blijven uitsluitend voor de service role'
);
select throws_ok(
  $$select app.claim_dynamic_import_run(
    'd9000000-0000-4000-8000-000000000099',
    55
  )$$,
  '42501',
  'SERVICE_ROLE_REQUIRED',
  'een uitvoercontext zonder expliciete serviceclaim faalt gesloten'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.create_dynamic_import_upload(
  'd5000000-0000-4000-8000-000000000001',
  'd6000000-0000-4000-8000-000000000001',
  'd1000000-0000-4000-8000-000000000001',
  'leden.csv',
  repeat('a', 64),
  ';',
  500,
  7,
  8,
  repeat('A', 24),
  repeat('A', 16),
  1,
  repeat('f', 64),
  24,
  null
);
create temporary table dry_run_mapping_workspace as
select app.get_dynamic_import_mapping_workspace(
  'd5000000-0000-4000-8000-000000000001'
) result;
select app.save_dynamic_import_mapping(
  'd5000000-0000-4000-8000-000000000001',
  0,
  (select result->>'catalogHash' from dry_run_mapping_workspace),
  repeat('b', 64),
  jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('0', 64),
      'target',
      jsonb_build_object(
        'kind', 'member_field', 'field', 'external_member_id'
      )
    ),
    jsonb_build_object(
      'columnIndex', 1,
      'sourceHeaderHash', repeat('1', 64),
      'target',
      jsonb_build_object('kind', 'member_field', 'field', 'first_name')
    ),
    jsonb_build_object(
      'columnIndex', 2,
      'sourceHeaderHash', repeat('2', 64),
      'target',
      jsonb_build_object('kind', 'member_field', 'field', 'last_name')
    ),
    jsonb_build_object(
      'columnIndex', 3,
      'sourceHeaderHash', repeat('3', 64),
      'target',
      jsonb_build_object('kind', 'member_field', 'field', 'email')
    ),
    jsonb_build_object(
      'columnIndex', 4,
      'sourceHeaderHash', repeat('4', 64),
      'target',
      jsonb_build_object('kind', 'member_field', 'field', 'team')
    ),
    jsonb_build_object(
      'columnIndex', 5,
      'sourceHeaderHash', repeat('5', 64),
      'target',
      jsonb_build_object(
        'kind', 'member_field', 'field', 'date_of_birth'
      )
    ),
    jsonb_build_object(
      'columnIndex', 6,
      'sourceHeaderHash', repeat('6', 64),
      'target',
      jsonb_build_object('kind', 'member_field', 'field', 'gender')
    ),
    jsonb_build_object(
      'columnIndex', 7,
      'sourceHeaderHash', repeat('7', 64),
      'target',
      jsonb_build_object(
        'kind',
        'product_size',
        'articleId',
        'd2000000-0000-4000-8000-000000000001'
      )
    )
  ),
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  null,
  null,
  null
);
select is(
  app.begin_dynamic_import_dry_run(
    'd7000000-0000-4000-8000-000000000001',
    'd5000000-0000-4000-8000-000000000001',
    1,
    'd8000000-0000-4000-8000-000000000001',
    repeat('8', 64),
    'dc000000-0000-4000-8000-000000000001'
  )->>'status',
  'queued_preview',
  'beheerder queueert een actor- en mappinggebonden dry-run'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_dry_run(
    'd7000000-0000-4000-8000-000000000001',
    null,
    0,
    100
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan de beheerder-dry-run niet lezen'
);
reset role;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select app.claim_dynamic_import_run(
    'd9000000-0000-4000-8000-000000000098',
    null
  )$$,
  '22023',
  'DYNAMIC_IMPORT_CLAIM_INVALID',
  'een NULL leaseperiode wordt expliciet geweigerd'
);
create temporary table claimed_dry_run as
select app.claim_dynamic_import_run(
  'd9000000-0000-4000-8000-000000000001',
  55
) result;
select is(
  (select result #>> '{job,phase}' from claimed_dry_run),
  'preview',
  'serviceworker claimt de previewfase'
);
select is(
  app.stage_dynamic_import_rows(
    'd7000000-0000-4000-8000-000000000001',
    'd9000000-0000-4000-8000-000000000001',
    (select (result #>> '{job,generation}')::integer from claimed_dry_run),
    2,
    jsonb_build_array(
      jsonb_build_object(
        'sourceRow', 2,
        'fields', jsonb_build_object(
          'external_member_id', 'NEW-1',
          'first_name', 'Noor',
          'last_name', 'Nieuw',
          'email', 'ouder-noor@example.test',
          'team', 'JO13-1',
          'date_of_birth', '2014-02-03',
          'gender', 'female'
        ),
        'sizes', jsonb_build_object(
          'd2000000-0000-4000-8000-000000000001', '152'
        ),
        'errors', '[]'::jsonb
      ),
      jsonb_build_object(
        'sourceRow', 3,
        'fields', jsonb_build_object(
          'external_member_id', 'EX-1',
          'first_name', 'Bestaand',
          'last_name', 'Lid',
          'email', 'ouder-bestaand@example.test',
          'team', 'JO15-1',
          'date_of_birth', '2012-01-01',
          'gender', 'male'
        ),
        'sizes', jsonb_build_object(
          'd2000000-0000-4000-8000-000000000001', '164'
        ),
        'errors', '[]'::jsonb
      ),
      jsonb_build_object(
        'sourceRow', 4,
        'fields', jsonb_build_object(
          'external_member_id', 'NEW-2',
          'first_name', 'Sam',
          'last_name', 'Onbekend',
          'email', 'ouder-sam@example.test',
          'team', 'JO11-1',
          'date_of_birth', '2016-04-05',
          'gender', 'other'
        ),
        'sizes', jsonb_build_object(
          'd2000000-0000-4000-8000-000000000001', 'XXXL'
        ),
        'errors', '[]'::jsonb
      ),
      jsonb_build_object(
        'sourceRow', 5,
        'fields', jsonb_build_object(
          'external_member_id', 'EX-SKIP',
          'first_name', 'Exact',
          'last_name', 'Ongewijzigd',
          'email', 'ouder-exact@example.test',
          'team', 'JO12-1',
          'date_of_birth', '2013-02-02',
          'gender', 'female'
        ),
        'sizes', '{}'::jsonb,
        'errors', '[]'::jsonb
      ),
      jsonb_build_object(
        'sourceRow', 6,
        'fields', jsonb_build_object(
          'external_member_id', 'EX-UPDATE',
          'first_name', 'Team',
          'last_name', 'Wijziging',
          'email', 'ouder-team@example.test',
          'team', 'JO10-2',
          'date_of_birth', '2015-03-03',
          'gender', 'male'
        ),
        'sizes', '{}'::jsonb,
        'errors', '[]'::jsonb
      ),
      jsonb_build_object(
        'sourceRow', 7,
        'fields', jsonb_build_object(
          'external_member_id', 'EX-PARENT',
          'first_name', 'Eigen',
          'last_name', 'Keuze',
          'email', 'ouder-keuze@example.test',
          'team', 'JO14-1',
          'date_of_birth', '2011-04-04',
          'gender', 'female'
        ),
        'sizes', jsonb_build_object(
          'd2000000-0000-4000-8000-000000000001', '164'
        ),
        'errors', '[]'::jsonb
      ),
      jsonb_build_object(
        'sourceRow', 8,
        'fields', jsonb_build_object(
          'first_name', 'Dubbel',
          'last_name', 'Profiel',
          'team', 'JO9-1',
          'date_of_birth', '2017-05-05',
          'gender', 'male'
        ),
        'sizes', '{}'::jsonb,
        'errors', '[]'::jsonb
      )
    )
  )->>'complete',
  'true',
  'alleen geselecteerde, getypeerde kolommen zijn hervatbaar gestaged'
);
select is(
  app.analyze_dynamic_import_chunk(
    'd7000000-0000-4000-8000-000000000001',
    'd9000000-0000-4000-8000-000000000001',
    (select (result #>> '{job,generation}')::integer from claimed_dry_run),
    250
  )->>'complete',
  'true',
  'dry-runanalyse is begrensd en hervatbaar'
);
select is(
  app.finalize_dynamic_import_dry_run(
    'd7000000-0000-4000-8000-000000000001',
    'd9000000-0000-4000-8000-000000000001',
    (select (result #>> '{job,generation}')::integer from claimed_dry_run)
  )->>'status',
  'previewed',
  'dry-run wordt pas na exact alle bronrijen atomair voltooid'
);
reset role;

select is(
  (
    select outcome::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 2
  ),
  'create',
  'nieuwe exacte Sportlink-identiteit wordt create'
);
select is(
  (
    select outcome::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 3
  ),
  'protected',
  'bevestigde maat blijft beschermd'
);
select is(
  (
    select outcome::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 4
  ),
  'conflict',
  'veilige onbekende maat wordt een niet-fuzzy conflict'
);
select is(
  (
    select blocking
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 4
  ),
  false,
  'maatconflict blokkeert allocatie maar niet de veilige lidcommit'
);
select is(
  (
    select outcome::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 5
  ),
  'skip',
  'exact gelijke geselecteerde gegevens worden een echte skip'
);
select is(
  (
    select outcome::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 6
  ),
  'update',
  'een veilige seizoenswijziging wordt expliciet als update getoond'
);
select is(
  (
    select outcome::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 7
  ),
  'protected',
  'een door de ouder gekozen Anders-conflict is beschermd'
);
select is(
  (
    select outcome::text || ':' || blocking::text
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row = 8
  ),
  'conflict:true',
  'een dubbelzinnige naam-DOB-identiteit blokkeert alleen die rij'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  (
    select count(*)
    from app.dynamic_import_runs
    where id = 'd7000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'de AAL2-eigenaar kan de eigen importrun rechtstreeks lezen'
);
select is(
  (
    select count(*)
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
  ),
  7::bigint,
  'de AAL2-eigenaar kan uitsluitend de veilige eigen rijresultaten lezen'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select is(
  (
    select count(*)
    from app.dynamic_import_runs
    where id = 'd7000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'dezelfde beheerder ziet zonder MFA geen importrun'
);
select throws_ok(
  $$select app.get_dynamic_import_dry_run(
    'd7000000-0000-4000-8000-000000000001',
    null,
    0,
    100
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'de import-RPC weigert de eigenaar op AAL1'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
select is(
  (
    select count(*)
    from app.dynamic_import_runs
    where id = 'd7000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'een andere AAL2-beheerder ziet de actor-gebonden run niet'
);
select throws_ok(
  $$select app.get_dynamic_import_dry_run(
    'd7000000-0000-4000-8000-000000000001',
    null,
    0,
    100
  )$$,
  'P0002',
  'DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND',
  'de actorbinding lekt aan een andere beheerder niet dat de run bestaat'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000004","aal":"aal2"}',
  true
);
select is(
  (
    select count(*)
    from app.dynamic_import_row_results
    where run_id = 'd7000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'uitgifte ziet geen importresultaten'
);
select throws_ok(
  $$select app.get_dynamic_import_dry_run(
    'd7000000-0000-4000-8000-000000000001',
    null,
    0,
    100
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan de import-RPC niet gebruiken'
);
reset role;
select is(
  (
    select count(*)
    from private.import_staging_payloads
    where batch_id = 'd5000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'ruwe CSV inclusief genegeerde kolommen is direct na dry-run verwijderd'
);
select ok(
  not exists(
    select 1
    from app.audit_logs
    where entity_id in (
      'd5000000-0000-4000-8000-000000000001',
      'd7000000-0000-4000-8000-000000000001'
    )
      and metadata::text ~* 'Noor|ouder-noor|2014-02-03|XXXL'
  ),
  'dry-runaudit bevat geen namen, e-mail, DOB of maatbronwaarden'
);
select is(
  (select count(*) from private.parent_portal_grants),
  0::bigint,
  'dry-run verleent geen portaaltoegang'
);
select is(
  (select count(*) from private.email_jobs),
  0::bigint,
  'dry-run enqueueet geen e-mail'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.authorize_dynamic_import_commit(
    'd7000000-0000-4000-8000-000000000001',
    (
      select plan_hash
      from app.dynamic_import_runs
      where id = 'd7000000-0000-4000-8000-000000000001'
    ),
    'da000000-0000-4000-8000-000000000001',
    repeat('9', 64),
    'dc000000-0000-4000-8000-000000000002'
  )->>'status',
  'commit_queued',
  'beheerder bevestigt exact het getoonde immutable dry-runplan'
);
reset role;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
create temporary table claimed_import_commit as
select app.claim_dynamic_import_run(
  'db000000-0000-4000-8000-000000000001',
  55
) result;
select is(
  (select result #>> '{job,phase}' from claimed_import_commit),
  'commit',
  'serviceworker claimt een afzonderlijke commitfase'
);
reset role;
update app.release_feature_flags
set enabled = false
where key = 'dynamic_import_v2';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select app.commit_dynamic_import_chunk(
    'd7000000-0000-4000-8000-000000000001',
    'db000000-0000-4000-8000-000000000001',
    (
      select (result #>> '{job,generation}')::integer
      from claimed_import_commit
    ),
    250
  )$$,
  '55000',
  'DYNAMIC_IMPORT_DISABLED',
  'de databasefeaturepoort stopt ook een reeds geclaimde commit'
);
reset role;
update app.release_feature_flags
set enabled = true
where key = 'dynamic_import_v2';
update app.seasons
set status = 'archived'
where id = 'd1000000-0000-4000-8000-000000000001';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select app.commit_dynamic_import_chunk(
    'd7000000-0000-4000-8000-000000000001',
    'db000000-0000-4000-8000-000000000001',
    (
      select (result #>> '{job,generation}')::integer
      from claimed_import_commit
    ),
    250
  )$$,
  '40001',
  'DYNAMIC_IMPORT_STATE_DRIFT',
  'een gesloten of niet-actief seizoen stopt iedere commitchunk'
);
reset role;
update app.seasons
set status = 'open'
where id = 'd1000000-0000-4000-8000-000000000001';
update app.article_variants
set size = '164-gewijzigd'
where id = 'd3000000-0000-4000-8000-000000000002';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select app.commit_dynamic_import_chunk(
    'd7000000-0000-4000-8000-000000000001',
    'db000000-0000-4000-8000-000000000001',
    (
      select (result #>> '{job,generation}')::integer
      from claimed_import_commit
    ),
    250
  )$$,
  '40001',
  'DYNAMIC_IMPORT_STATE_DRIFT',
  'catalogusdrift stopt iedere commitchunk vóór een mutatie'
);
reset role;
update app.article_variants
set size = '164'
where id = 'd3000000-0000-4000-8000-000000000002';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(
  app.commit_dynamic_import_chunk(
    'd7000000-0000-4000-8000-000000000001',
    'db000000-0000-4000-8000-000000000001',
    (
      select (result #>> '{job,generation}')::integer
      from claimed_import_commit
    ),
    250
  )->>'complete',
  'true',
  'de commit heranalyseert en verwerkt alle rijen in één transactionele chunk'
);
reset role;
select ok(
  exists(
    select 1
    from app.member_size_selection_history history
    where history.import_run_id =
        'd7000000-0000-4000-8000-000000000001'
      and history.import_source_row in (2, 4)
      and history.selection_source = 'import'
      and history.correlation_id =
        'dc000000-0000-4000-8000-000000000001'
      and history.actor_user_id =
        'd0000000-0000-4000-8000-000000000001'
  ),
  'maathistorie bewaart run, bronrijnummer, correlatie en importactor zonder CSV'
);
select is(
  (
    select string_agg(
      source_row::text || ':' || commit_disposition,
      ',' order by source_row
    )
    from private.dynamic_import_row_plans
    where run_id = 'd7000000-0000-4000-8000-000000000001'
      and source_row in (5, 6, 8)
  ),
  '5:skipped,6:applied,8:blocked',
  'skip, veilige update en blokkerende identiteit krijgen afzonderlijke disposities'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'members.import.row.processed'
      and metadata->>'runId' = 'd7000000-0000-4000-8000-000000000001'
  ),
  7::bigint,
  'iedere bronrij krijgt transactioneel exact één append-only audit-event'
);
select is(
  (
    select string_agg(
      (audit.metadata->>'sourceRow') || ':' ||
      (audit.metadata->>'rowOutcome') || ':' ||
      (audit.metadata->>'commitDisposition'),
      ',' order by (audit.metadata->>'sourceRow')::integer
    )
    from app.audit_logs audit
    where audit.action = 'members.import.row.processed'
      and audit.metadata->>'runId' = 'd7000000-0000-4000-8000-000000000001'
  ),
  '2:create:applied,3:protected:applied,4:conflict:applied,5:skip:skipped,6:update:applied,7:protected:applied,8:conflict:blocked',
  'create, update, maatconflict, protected, skip en blocked zijn duurzaam onderscheiden'
);
select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.action = 'members.import.row.processed'
      and audit.metadata->>'runId' = 'd7000000-0000-4000-8000-000000000001'
      and (
        select array_agg(key order by key)
        from jsonb_object_keys(audit.metadata) key
      ) is distinct from array[
        'articleIds',
        'batchId',
        'changeCount',
        'commitDisposition',
        'conflictCount',
        'protectedCount',
        'rowOutcome',
        'runId',
        'selectedFieldNames',
        'sourceRow'
      ]::text[]
  ),
  'per-rijaudit gebruikt uitsluitend de vaste veilige metadatawhitelist'
);
select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.action = 'members.import.row.processed'
      and audit.metadata->>'runId' = 'd7000000-0000-4000-8000-000000000001'
      and audit.metadata::text ~* 'Noor|ouder-noor|2014-02-03|XXXL'
  ),
  'per-rijaudit bevat geen naam, e-mail, DOB of ruwe maatwaarde'
);
select is(
  (
    select count(*)
    from app.audit_logs audit
    where audit.action = 'members.import.row.processed'
      and audit.metadata->>'runId' = 'd7000000-0000-4000-8000-000000000001'
      and audit.metadata->>'commitDisposition' in ('applied', 'skipped')
      and audit.entity_type = 'member'
      and exists(
        select 1 from app.members member where member.id = audit.entity_id
      )
  ),
  6::bigint,
  'iedere toegepaste of overgeslagen rij blijft aan het concrete lid gekoppeld'
);
update app.seasons
set status = 'archived'
where id = 'd1000000-0000-4000-8000-000000000001';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select app.finalize_dynamic_import_commit(
    'd7000000-0000-4000-8000-000000000001',
    'db000000-0000-4000-8000-000000000001',
    (
      select (result #>> '{job,generation}')::integer
      from claimed_import_commit
    )
  )$$,
  '40001',
  'DYNAMIC_IMPORT_STATE_DRIFT',
  'ook de commitfinalizer hercontroleert seizoen en catalogus'
);
reset role;
update app.seasons
set status = 'open'
where id = 'd1000000-0000-4000-8000-000000000001';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(
  app.finalize_dynamic_import_commit(
    'd7000000-0000-4000-8000-000000000001',
    'db000000-0000-4000-8000-000000000001',
    (
      select (result #>> '{job,generation}')::integer
      from claimed_import_commit
    )
  )->>'status',
  'committed',
  'commitfinalisatie sluit de run exact eenmaal af'
);
reset role;

select is(
  (
    select count(*)
    from app.members
    where relation_number in ('NEW-1', 'NEW-2')
  ),
  2::bigint,
  'nieuwe leden worden exact eenmaal aangemaakt'
);
select is(
  (
    select sensitive.date_of_birth
    from app.members member
    join private.member_sensitive_identity sensitive
      on sensitive.member_id = member.id
    where member.relation_number = 'NEW-1'
  ),
  date '2014-02-03',
  'geselecteerde DOB wordt privé en canoniek opgeslagen'
);
select is(
  (
    select size.article_variant_id
    from app.member_article_sizes size
    where size.member_id = 'd4000000-0000-4000-8000-000000000001'
      and size.season_id = 'd1000000-0000-4000-8000-000000000001'
      and size.article_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'd3000000-0000-4000-8000-000000000001'::uuid,
  'bestaande bevestigde maat is niet stil overschreven'
);
select is(
  (
    select size.selection_status::text
    from app.members member
    join app.member_article_sizes size on size.member_id = member.id
    where member.relation_number = 'NEW-1'
      and size.season_id = 'd1000000-0000-4000-8000-000000000001'
      and size.article_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'imported_unconfirmed',
  'herkende importmaat blijft voorgeselecteerd maar onbevestigd'
);
select is(
  (
    select size.selection_status::text || ':' || size.raw_value
    from app.members member
    join app.member_article_sizes size on size.member_id = member.id
    where member.relation_number = 'NEW-2'
      and size.season_id = 'd1000000-0000-4000-8000-000000000001'
      and size.article_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'conflict:XXXL',
  'onbekende maat blijft conflict zonder fictieve variant'
);
select is(
  (
    select
      size.selection_status::text || ':' ||
      size.selection_source::text || ':' ||
      size.raw_value || ':' ||
      size.member_note
    from app.member_article_sizes size
    where size.member_id = 'd4000000-0000-4000-8000-000000000004'
      and size.season_id = 'd1000000-0000-4000-8000-000000000001'
      and size.article_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'conflict:parent:Eigen pasvorm:Graag samen met de kledingcommissie meten',
  'ouder-Anders en toelichting worden niet stil door herimport overschreven'
);
select is(
  (
    select member.team || ':' || member_season.team_name
    from app.members member
    join app.member_seasons member_season
      on member_season.member_id = member.id
      and member_season.season_id = 'd1000000-0000-4000-8000-000000000001'
    where member.id = 'd4000000-0000-4000-8000-000000000003'
  ),
  'JO10-2:JO10-2',
  'veilige teamupdate blijft lid- en seizoensgebonden consistent'
);
select ok(
  (
    select
      member.updated_at = before.member_updated_at
      and member.imported_from_batch_id is not distinct from
        before.imported_from_batch_id
      and member_season.updated_at = before.member_season_updated_at
      and member_season.source_import_batch_id is not distinct from
        before.source_import_batch_id
    from app.members member
    join app.member_seasons member_season
      on member_season.member_id = member.id
      and member_season.season_id = 'd1000000-0000-4000-8000-000000000001'
    cross join skip_member_before before
    where member.id = 'd4000000-0000-4000-8000-000000000002'
  ),
  'een echte skip wijzigt geen timestamp of importprovenance'
);
select is(
  (
    select count(*)
    from app.action_items item
    where item.type = 'size_conflict'
      and item.status = 'open'
      and item.safe_context->>'articleId' =
        'd2000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'maatconflict maakt exact één dedupebaar beheeractiepunt'
);
select is(
  (
    select count(*)
    from app.action_items item
    where item.type = 'import_row_conflict'
      and item.status = 'open'
      and item.object_id = 'd5000000-0000-4000-8000-000000000001'
      and item.safe_context->>'sourceRow' = '8'
  ),
  1::bigint,
  'dubbelzinnige identiteit maakt exact één PII-vrij beheeractiepunt'
);
select ok(
  not exists(
    select 1
    from app.action_items item
    where item.safe_context::text ~*
      'XXXL|Noor|ouder-noor|2014-02-03|Dubbel|ouder-een|2017-05-05'
  ),
  'actiepunten bevatten geen ruwe maat, naam, e-mail of DOB'
);
select is(
  (
    select string_agg(source_row::text, ',' order by source_row)
    from private.dynamic_import_selected_rows
    where run_id = 'd7000000-0000-4000-8000-000000000001'
  ),
  '8',
  'alleen de blokkende geselecteerde rij blijft tijdelijk reconcilieerbaar'
);
select is(
  (
    select count(*)
    from private.dynamic_import_row_plans
    where run_id = 'd7000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'tijdelijke state- en analyseplannen zijn na succes direct gepurged'
);
select is(
  (select count(*) from private.parent_portal_grants),
  0::bigint,
  'commit verleent geen portaaltoegang'
);
select is(
  (select count(*) from private.email_jobs),
  0::bigint,
  'commit enqueueet geen e-mail'
);
select is(
  (select count(*) from app.member_orders),
  0::bigint,
  'import maakt geen pakket- of legacybestelling'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.authorize_dynamic_import_commit(
    'd7000000-0000-4000-8000-000000000001',
    (
      select plan_hash
      from app.dynamic_import_runs
      where id = 'd7000000-0000-4000-8000-000000000001'
    ),
    'da000000-0000-4000-8000-000000000001',
    repeat('9', 64),
    null
  )->>'reused',
  'true',
  'verloren commitantwoord is veilig idempotent te herhalen'
);
select is(
  app.get_dynamic_import_blocked_row(
    'd7000000-0000-4000-8000-000000000001',
    8
  )->>'sourceRow',
  '8',
  'de AAL2-eigenaar kan de tijdelijk bewaarde blokkende rij inspecteren'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_blocked_row(
    'd7000000-0000-4000-8000-000000000001',
    8
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'de eigenaar krijgt zonder MFA geen tijdelijk conflictdetail'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_blocked_row(
    'd7000000-0000-4000-8000-000000000001',
    8
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie krijgt geen beheerderconflictdetail'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_blocked_row(
    'd7000000-0000-4000-8000-000000000001',
    8
  )$$,
  'P0002',
  'DYNAMIC_IMPORT_BLOCKED_ROW_NOT_FOUND',
  'een andere beheerder krijgt geen bestaan- of conflictdetail prijs'
);
reset role;

select is(
  app.get_operational_health_v4() #>> '{importRuns,failed}',
  '0',
  'operationele health telt importfouten'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'members.import.row.processed'
      and metadata->>'runId' = 'd7000000-0000-4000-8000-000000000001'
  ),
  7::bigint,
  'idempotente herhaling maakt geen dubbele per-rijaudit'
);

select * from finish();
rollback;
