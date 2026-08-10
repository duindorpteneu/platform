begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('c0000000-0000-4000-8000-000000000001', 'Mappingbeheer', 'beheerder'),
  ('c0000000-0000-4000-8000-000000000002', 'Mappingcommissie', 'kledingcommissie');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('c1000000-0000-4000-8000-000000000001', '2045/2046 mapping', 10000, 'open'),
  ('c1000000-0000-4000-8000-000000000002', '2046/2047 ander seizoen', 10000, 'open');
update app.app_settings
set active_season_id = 'c1000000-0000-4000-8000-000000000001'
where id = true;
insert into app.articles(id, name, code, active, sort_order) values
  ('c2000000-0000-4000-8000-000000000001', 'Broek', 'BROEK', true, 1),
  ('c2000000-0000-4000-8000-000000000002', 'Ander seizoen', 'ANDER', true, 2);
insert into app.article_variants(id, article_id, size, sku, active, sort_order) values
  ('c3000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', '152', 'BR-152', true, 1),
  ('c3000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000002', 'M', null, true, 1);
insert into app.article_variant_aliases(
  article_id, article_variant_id, alias, alias_normalized
) values(
  'c2000000-0000-4000-8000-000000000001',
  'c3000000-0000-4000-8000-000000000001',
  'maat 152',
  private.normalize_size_match('maat 152')
);
insert into app.article_seasons(article_id, season_id) values
  ('c2000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001'),
  ('c2000000-0000-4000-8000-000000000002', 'c1000000-0000-4000-8000-000000000002');
update app.release_feature_flags set enabled = true where key = 'dynamic_import_v2';

select has_table('app', 'import_mapping_presets', 'mappingpresets bestaan');
select has_table('app', 'import_mapping_revisions', 'immutable mappingrevisies bestaan');
select ok(
  not has_table_privilege('authenticated', 'app.import_mapping_revisions', 'INSERT'),
  'authenticated kan mappingrevisies niet rechtstreeks schrijven'
);
select ok(
  not has_table_privilege('service_role', 'app.import_mapping_revisions', 'SELECT'),
  'service-role krijgt geen brede mappingtabelread'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_mapping_workspace(
    'c4000000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan mappingworkspace niet lezen'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.create_dynamic_import_upload(
  'c4000000-0000-4000-8000-000000000001',
  'c5000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001',
  'leden.csv',
  repeat('a', 64),
  ';',
  120,
  2,
  3,
  repeat('A', 24),
  repeat('A', 16),
  1,
  repeat('f', 64),
  24,
  null
);
create temporary table mapping_workspace as
select app.get_dynamic_import_mapping_workspace(
  'c4000000-0000-4000-8000-000000000001'
) result;
select is(
  jsonb_array_length((select result->'articles' from mapping_workspace)),
  1,
  'catalogus bevat uitsluitend actieve producten uit het batchseizoen'
);
select is(
  (select result #>> '{articles,0,variants,0,aliases,0}' from mapping_workspace),
  'maat 152',
  'catalogus bevat de expliciete productgebonden alias'
);
select ok(
  (select result->>'catalogHash' from mapping_workspace) ~ '^[0-9a-f]{64}$',
  'catalogushash is een vaste digest'
);

create temporary table first_mapping as
select app.save_dynamic_import_mapping(
  'c4000000-0000-4000-8000-000000000001',
  0,
  (select result->>'catalogHash' from mapping_workspace),
  repeat('b', 64),
  jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('c', 64),
      'target', jsonb_build_object('kind', 'member_field', 'field', 'external_member_id')
    ),
    jsonb_build_object(
      'columnIndex', 2,
      'sourceHeaderHash', repeat('d', 64),
      'target', jsonb_build_object(
        'kind', 'product_size',
        'articleId', 'c2000000-0000-4000-8000-000000000001'
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
) result;
select is(
  (select result->>'revision' from first_mapping),
  '1',
  'eerste gevalideerde mapping krijgt revisie één'
);
select is(
  (select result->>'reused' from first_mapping),
  'false',
  'eerste mappingwrite is nieuw'
);
select ok(
  not exists(
    select 1
    from app.import_mapping_revisions
    where mapping::text ~* 'Relatienummer|Maat Broek|Noa|example'
  ),
  'mappingrevisie bevat geen bronheadertekst of bronwaarden'
);
select is(
  app.save_dynamic_import_mapping(
    'c4000000-0000-4000-8000-000000000001',
    0,
    (select result->>'catalogHash' from mapping_workspace),
    repeat('b', 64),
    jsonb_build_array(
      jsonb_build_object(
        'columnIndex', 0,
        'sourceHeaderHash', repeat('c', 64),
        'target', jsonb_build_object('kind', 'member_field', 'field', 'external_member_id')
      ),
      jsonb_build_object(
        'columnIndex', 2,
        'sourceHeaderHash', repeat('d', 64),
        'target', jsonb_build_object(
          'kind', 'product_size',
          'articleId', 'c2000000-0000-4000-8000-000000000001'
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
  )->>'reused',
  'true',
  'retry met dezelfde mapping is idempotent'
);
select throws_ok(
  $$select app.save_dynamic_import_mapping(
    'c4000000-0000-4000-8000-000000000001',
    0,
    (select result->>'catalogHash' from mapping_workspace),
    repeat('b', 64),
    jsonb_build_array(jsonb_build_object(
      'columnIndex', 1,
      'sourceHeaderHash', repeat('e', 64),
      'target', jsonb_build_object('kind', 'member_field', 'field', 'first_name')
    )),
    jsonb_build_object(
      'fillEmptyValues', true,
      'updateImportedUnconfirmedSizes', true,
      'protectConfirmedSizes', true,
      'ignoreEmptySourceValues', true
    ),
    null,
    null,
    null
  )$$,
  '40001',
  'DYNAMIC_IMPORT_REVISION_CHANGED',
  'dezelfde oude revisie kan geen andere mapping schrijven'
);

create temporary table saved_preset as
select app.save_dynamic_import_mapping_preset(
  null,
  null,
  'Sportlink standaard',
  jsonb_build_array(jsonb_build_object(
    'sourceHeaderKey', 'maat broek',
    'target', jsonb_build_object(
      'kind', 'product_size',
      'articleId', 'c2000000-0000-4000-8000-000000000001'
    )
  )),
  null
) result;
select is(
  (select result->>'revision' from saved_preset),
  '1',
  'beheerder bewaart een gedeelde preset zonder bronwaarden'
);
select throws_ok(
  $$select app.save_dynamic_import_mapping_preset(
    null,
    null,
    'Andere naam',
    jsonb_build_array(
      jsonb_build_object(
        'sourceHeaderKey', 'e-mail',
        'target', jsonb_build_object('kind', 'member_field', 'field', 'email')
      ),
      jsonb_build_object(
        'sourceHeaderKey', 'e-mail',
        'target', jsonb_build_object('kind', 'member_field', 'field', 'first_name')
      )
    ),
    null
  )$$,
  '22023',
  'DYNAMIC_IMPORT_PRESET_INVALID',
  'preset weigert dubbele genormaliseerde bronheaders'
);
select is(
  app.archive_dynamic_import_mapping_preset(
    (select (result->>'id')::uuid from saved_preset),
    1,
    null
  )->>'archived',
  'true',
  'preset wordt niet verwijderd maar geaudit gearchiveerd'
);
reset role;

insert into app.article_variants(id, article_id, size, active, sort_order)
values(
  'c3000000-0000-4000-8000-000000000003',
  'c2000000-0000-4000-8000-000000000001',
  '164',
  true,
  2
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.save_dynamic_import_mapping(
    'c4000000-0000-4000-8000-000000000001',
    1,
    (select result->>'catalogHash' from mapping_workspace),
    repeat('f', 64),
    jsonb_build_array(jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('1', 64),
      'target', jsonb_build_object('kind', 'member_field', 'field', 'external_member_id')
    )),
    jsonb_build_object(
      'fillEmptyValues', true,
      'updateImportedUnconfirmedSizes', true,
      'protectConfirmedSizes', true,
      'ignoreEmptySourceValues', true
    ),
    null,
    null,
    null
  )$$,
  '40001',
  'DYNAMIC_IMPORT_CATALOG_CHANGED',
  'catalogusdrift maakt een eerder getoonde mapping ongeldig'
);
reset role;

select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.entity_id = 'c4000000-0000-4000-8000-000000000001'
      and audit.metadata::text ~* 'leden.csv|Sportlink|maat broek|example'
  ),
  'mappingaudit bevat geen bestandsnaam, presetnaam, header of bronwaarde'
);

select * from finish();
rollback;
