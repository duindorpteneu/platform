begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values('a1700000-0000-4000-8000-000000000001', 'Fleximport beheer', 'beheerder');
insert into app.seasons(id, name, default_amount_cents, status)
values('a1710000-0000-4000-8000-000000000001', '2051/2052 fleximport', 10000, 'open');
update app.app_settings
set active_season_id = 'a1710000-0000-4000-8000-000000000001'
where id = true;
update app.release_feature_flags set enabled = true where key = 'dynamic_import_v2';

insert into app.articles(id, name, code, active, sort_order)
values('a1720000-0000-4000-8000-000000000001', 'Flexbroek', 'FLEXBROEK', true, 1);
insert into app.article_variants(id, article_id, size, sku, active, sort_order)
values(
  'a1730000-0000-4000-8000-000000000001',
  'a1720000-0000-4000-8000-000000000001',
  '152',
  'FLEX-152',
  true,
  1
);
insert into app.article_seasons(article_id, season_id)
values(
  'a1720000-0000-4000-8000-000000000001',
  'a1710000-0000-4000-8000-000000000001'
);

insert into app.import_batches(
  id, file_name, checksum, actor_user_id, status, season_id,
  client_request_id, schema_version, dynamic_status, encoding, delimiter,
  byte_count, source_row_count, source_column_count, policy,
  mapping_hash, catalog_hash, next_source_row, expires_at
) values(
  'a1740000-0000-4000-8000-000000000001',
  'flex.csv',
  repeat('a', 64),
  'a1700000-0000-4000-8000-000000000001',
  'preview',
  'a1710000-0000-4000-8000-000000000001',
  'a1750000-0000-4000-8000-000000000001',
  2,
  'processing',
  'UTF-8',
  ';',
  100,
  1,
  6,
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  repeat('b', 64),
  repeat('c', 64),
  2,
  timezone('utc', now()) + interval '2 hours'
);

insert into app.import_mapping_revisions(
  id, batch_id, season_id, revision, mapping, mapping_hash,
  header_hash, catalog_hash, policy, created_by
) values(
  'a1760000-0000-4000-8000-000000000001',
  'a1740000-0000-4000-8000-000000000001',
  'a1710000-0000-4000-8000-000000000001',
  1,
  jsonb_build_array(
    jsonb_build_object('columnIndex', 0, 'sourceHeaderHash', repeat('0', 64), 'target', jsonb_build_object('kind', 'member_field', 'field', 'external_member_id')),
    jsonb_build_object('columnIndex', 1, 'sourceHeaderHash', repeat('1', 64), 'target', jsonb_build_object('kind', 'member_field', 'field', 'first_name')),
    jsonb_build_object('columnIndex', 2, 'sourceHeaderHash', repeat('2', 64), 'target', jsonb_build_object('kind', 'member_field', 'field', 'last_name')),
    jsonb_build_object('columnIndex', 3, 'sourceHeaderHash', repeat('3', 64), 'target', jsonb_build_object('kind', 'member_field', 'field', 'email')),
    jsonb_build_object('columnIndex', 4, 'sourceHeaderHash', repeat('4', 64), 'target', jsonb_build_object('kind', 'member_field', 'field', 'team')),
    jsonb_build_object('columnIndex', 5, 'sourceHeaderHash', repeat('5', 64), 'target', jsonb_build_object('kind', 'product_size', 'articleId', 'a1720000-0000-4000-8000-000000000001'))
  ),
  repeat('b', 64),
  repeat('d', 64),
  repeat('c', 64),
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  'a1700000-0000-4000-8000-000000000001'
);
update app.import_batches
set active_mapping_revision_id = 'a1760000-0000-4000-8000-000000000001'
where id = 'a1740000-0000-4000-8000-000000000001';
insert into private.dynamic_import_mapping_preferences(
  mapping_revision_id, ignore_optional_conflicts, created_by
) values(
  'a1760000-0000-4000-8000-000000000001',
  true,
  'a1700000-0000-4000-8000-000000000001'
);

insert into app.dynamic_import_runs(
  id, batch_id, mapping_revision_id, season_id, created_by,
  client_request_id, request_hash, status, source_row_count,
  next_source_row, next_analysis_source_row, next_commit_source_row,
  expires_at, started_at
) values(
  'a1770000-0000-4000-8000-000000000001',
  'a1740000-0000-4000-8000-000000000001',
  'a1760000-0000-4000-8000-000000000001',
  'a1710000-0000-4000-8000-000000000001',
  'a1700000-0000-4000-8000-000000000001',
  'a1780000-0000-4000-8000-000000000001',
  repeat('e', 64),
  'staging',
  1,
  2,
  2,
  2,
  timezone('utc', now()) + interval '2 hours',
  timezone('utc', now())
);
insert into private.dynamic_import_run_leases(
  run_id, claim_token, generation, claimed_at, expires_at
) values(
  'a1770000-0000-4000-8000-000000000001',
  'a1790000-0000-4000-8000-000000000001',
  1,
  timezone('utc', now()),
  timezone('utc', now()) + interval '55 seconds'
);

create temporary table filtered_rows(result jsonb);
grant select, insert on filtered_rows to service_role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into filtered_rows(result)
select app.filter_dynamic_import_optional_conflicts(
  'a1770000-0000-4000-8000-000000000001',
  'a1790000-0000-4000-8000-000000000001',
  1,
  jsonb_build_array(jsonb_build_object(
    'sourceRow', 2,
    'fields', jsonb_build_object(
      'external_member_id', 'FLEX-1',
      'first_name', 'Lid',
      'last_name', 'Zondervelden',
      'email', 'ouder-flex@example.test'
    ),
    'sizes', jsonb_build_object(
      'a1720000-0000-4000-8000-000000000001', 'XXXL'
    ),
    'errors', jsonb_build_array('invalid_team', 'invalid_gender', 'invalid_size_deadbeef')
  ))
);
select app.stage_dynamic_import_rows(
  'a1770000-0000-4000-8000-000000000001',
  'a1790000-0000-4000-8000-000000000001',
  1,
  2,
  (select result from filtered_rows)
);
reset role;

select is(
  (select result #> '{0,sizes}' from filtered_rows),
  '{}'::jsonb,
  'onbekende maat wordt in negeermodus niet duurzaam gestaged'
);
select is(
  (select result #> '{0,errors}' from filtered_rows),
  '[]'::jsonb,
  'optionele veldfouten worden in negeermodus verwijderd'
);
select is(
  private.dynamic_import_analyze_row(
    'a1770000-0000-4000-8000-000000000001', 2
  )->>'blocking',
  'false',
  'ontbrekend team blokkeert de gekozen flexibele import niet'
);
select is(
  private.dynamic_import_analyze_row(
    'a1770000-0000-4000-8000-000000000001', 2
  )->>'outcome',
  'create',
  'lid zonder optionele waarden blijft een create-uitkomst'
);

select * from finish();
rollback;
