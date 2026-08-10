begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'de000000-0000-4000-8000-000000000001',
  'Importidentiteit beheer',
  'beheerder'
);
insert into app.seasons(id, name, default_amount_cents, status)
values (
  'de100000-0000-4000-8000-000000000001',
  '2048/2049 importidentiteit',
  10000,
  'open'
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  active_for_season
) values
  (
    'de400000-0000-4000-8000-000000000001',
    'IDENT-A',
    'Alex',
    'Bestaand',
    'ouder-alex@example.test',
    'JO15-1',
    true
  ),
  (
    'de400000-0000-4000-8000-000000000002',
    'IDENT-B',
    'Bo',
    'Bestaand',
    'ouder-bo@example.test',
    'JO13-1',
    true
  ),
  (
    'de400000-0000-4000-8000-000000000003',
    'IDENT-C',
    'Chris',
    'Dubbel',
    'eerste-ouder@example.test',
    'JO11-1',
    true
  ),
  (
    'de400000-0000-4000-8000-000000000004',
    'IDENT-D',
    'Chris',
    'Dubbel',
    'tweede-ouder@example.test',
    'JO11-2',
    true
  );
update private.member_sensitive_identity
set date_of_birth = case member_id
  when 'de400000-0000-4000-8000-000000000001'::uuid then date '2012-01-01'
  when 'de400000-0000-4000-8000-000000000002'::uuid then date '2014-02-02'
  else date '2016-03-03'
end
where member_id in (
  'de400000-0000-4000-8000-000000000001',
  'de400000-0000-4000-8000-000000000002',
  'de400000-0000-4000-8000-000000000003',
  'de400000-0000-4000-8000-000000000004'
);

create or replace function pg_temp.prepare_identity_analysis(
  p_batch_id uuid,
  p_mapping_id uuid,
  p_run_id uuid,
  p_field_rows jsonb
)
returns void
language plpgsql
as $$
declare
  mapping_value jsonb := jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('0', 64),
      'target', jsonb_build_object(
        'kind', 'member_field', 'field', 'external_member_id'
      )
    ),
    jsonb_build_object(
      'columnIndex', 1,
      'sourceHeaderHash', repeat('1', 64),
      'target', jsonb_build_object(
        'kind', 'member_field', 'field', 'first_name'
      )
    ),
    jsonb_build_object(
      'columnIndex', 2,
      'sourceHeaderHash', repeat('2', 64),
      'target', jsonb_build_object(
        'kind', 'member_field', 'field', 'last_name'
      )
    ),
    jsonb_build_object(
      'columnIndex', 3,
      'sourceHeaderHash', repeat('3', 64),
      'target', jsonb_build_object(
        'kind', 'member_field', 'field', 'email'
      )
    ),
    jsonb_build_object(
      'columnIndex', 4,
      'sourceHeaderHash', repeat('4', 64),
      'target', jsonb_build_object(
        'kind', 'member_field', 'field', 'team'
      )
    ),
    jsonb_build_object(
      'columnIndex', 5,
      'sourceHeaderHash', repeat('5', 64),
      'target', jsonb_build_object(
        'kind', 'member_field', 'field', 'date_of_birth'
      )
    )
  );
  row_total integer := jsonb_array_length(p_field_rows);
begin
  insert into app.import_batches(
    id,
    file_name,
    checksum,
    actor_user_id,
    status,
    season_id,
    client_request_id,
    schema_version,
    dynamic_status,
    encoding,
    delimiter,
    byte_count,
    source_row_count,
    source_column_count,
    policy,
    mapping_hash,
    catalog_hash,
    preview_revision,
    next_source_row,
    expires_at
  )
  values(
    p_batch_id,
    'identity-check.csv',
    repeat('a', 64),
    'de000000-0000-4000-8000-000000000001',
    'preview',
    'de100000-0000-4000-8000-000000000001',
    p_batch_id,
    2,
    'processing',
    'UTF-8',
    ';',
    100,
    row_total,
    6,
    jsonb_build_object(
      'fillEmptyValues', true,
      'updateImportedUnconfirmedSizes', true,
      'protectConfirmedSizes', true,
      'ignoreEmptySourceValues', true
    ),
    repeat('b', 64),
    private.dynamic_import_catalog_hash(
      'de100000-0000-4000-8000-000000000001'
    ),
    1,
    row_total + 2,
    timezone('utc', now()) + interval '1 hour'
  );
  insert into app.import_mapping_revisions(
    id,
    batch_id,
    season_id,
    revision,
    mapping,
    mapping_hash,
    header_hash,
    catalog_hash,
    policy,
    created_by
  )
  values(
    p_mapping_id,
    p_batch_id,
    'de100000-0000-4000-8000-000000000001',
    1,
    mapping_value,
    repeat('b', 64),
    repeat('c', 64),
    private.dynamic_import_catalog_hash(
      'de100000-0000-4000-8000-000000000001'
    ),
    jsonb_build_object(
      'fillEmptyValues', true,
      'updateImportedUnconfirmedSizes', true,
      'protectConfirmedSizes', true,
      'ignoreEmptySourceValues', true
    ),
    'de000000-0000-4000-8000-000000000001'
  );
  update app.import_batches
  set active_mapping_revision_id = p_mapping_id
  where id = p_batch_id;
  insert into app.dynamic_import_runs(
    id,
    batch_id,
    mapping_revision_id,
    season_id,
    created_by,
    client_request_id,
    request_hash,
    status,
    source_row_count,
    next_source_row,
    expires_at,
    started_at
  )
  values(
    p_run_id,
    p_batch_id,
    p_mapping_id,
    'de100000-0000-4000-8000-000000000001',
    'de000000-0000-4000-8000-000000000001',
    p_run_id,
    repeat('d', 64),
    'staging',
    row_total,
    row_total + 2,
    timezone('utc', now()) + interval '1 hour',
    timezone('utc', now())
  );

  with source_rows as (
    select
      value fields,
      ordinality::integer + 1 source_row
    from jsonb_array_elements(p_field_rows) with ordinality
  ),
  selected_rows as (
    select
      source_row,
      jsonb_build_object(
        'sourceRow', source_row,
        'fields', fields,
        'sizes', '{}'::jsonb,
        'errors', '[]'::jsonb
      ) selected_values
    from source_rows
  )
  insert into private.dynamic_import_selected_rows(
    run_id,
    source_row,
    selected_values,
    row_hash,
    identity_key_hash,
    expires_at
  )
  select
    p_run_id,
    source_row,
    selected_values,
    encode(
      extensions.digest(convert_to(selected_values::text, 'UTF8'), 'sha256'),
      'hex'
    ),
    private.dynamic_import_identity_key_hash(selected_values->'fields'),
    timezone('utc', now()) + interval '1 hour'
  from selected_rows;
end;
$$;

select pg_temp.prepare_identity_analysis(
  'de500000-0000-4000-8000-000000000001',
  'de600000-0000-4000-8000-000000000001',
  'de700000-0000-4000-8000-000000000001',
  jsonb_build_array(jsonb_build_object(
    'external_member_id', 'IDENT-A',
    'first_name', 'Bo',
    'last_name', 'Bestaand',
    'email', 'ouder-bo@example.test',
    'team', 'JO13-1',
    'date_of_birth', '2014-02-02'
  ))
);
select is(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000001',
    2
  )->>'blocking',
  'true',
  'external ID en een andere exacte DOB-identiteit blokkeren'
);
select ok(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000001',
    2
  )->'reasonCodes' ? 'identity_cross_match',
  'cross-match krijgt een expliciete veilige reden'
);

select pg_temp.prepare_identity_analysis(
  'de500000-0000-4000-8000-000000000002',
  'de600000-0000-4000-8000-000000000002',
  'de700000-0000-4000-8000-000000000002',
  jsonb_build_array(jsonb_build_object(
    'external_member_id', 'IDENT-A',
    'first_name', 'Alex',
    'last_name', 'Bestaand',
    'email', 'ouder-alex@example.test',
    'team', 'JO15-1',
    'date_of_birth', '2012-01-02'
  ))
);
select ok(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000002',
    2
  )->'reasonCodes' ? 'date_of_birth_mismatch',
  'een afwijkende DOB overschrijft de bestaande identiteit nooit stil'
);

select pg_temp.prepare_identity_analysis(
  'de500000-0000-4000-8000-000000000003',
  'de600000-0000-4000-8000-000000000003',
  'de700000-0000-4000-8000-000000000003',
  jsonb_build_array(jsonb_build_object(
    'external_member_id', 'NIEUW-ID',
    'first_name', 'Bo',
    'last_name', 'Bestaand',
    'email', 'ouder-bo@example.test',
    'team', 'JO13-1',
    'date_of_birth', '2014-02-02'
  ))
);
select ok(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000003',
    2
  )->'reasonCodes' ? 'external_identity_requires_review',
  'een nieuw extern ID wordt niet automatisch aan een bestaande DOB-identiteit gekoppeld'
);

select pg_temp.prepare_identity_analysis(
  'de500000-0000-4000-8000-000000000004',
  'de600000-0000-4000-8000-000000000004',
  'de700000-0000-4000-8000-000000000004',
  jsonb_build_array(
    jsonb_build_object(
      'first_name', 'Dana',
      'last_name', 'Nieuw',
      'email', 'eerste@example.test',
      'team', 'JO9-1',
      'date_of_birth', '2018-04-04'
    ),
    jsonb_build_object(
      'first_name', 'Dana',
      'last_name', 'Nieuw',
      'email', 'tweede@example.test',
      'team', 'JO9-1',
      'date_of_birth', '2018-04-04'
    )
  )
);
select is(
  (
    select count(distinct identity_key_hash)
    from private.dynamic_import_selected_rows
    where run_id = 'de700000-0000-4000-8000-000000000004'
  ),
  1::bigint,
  'naam plus DOB blijft dezelfde bronidentiteit bij verschillende oudermails'
);
select ok(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000004',
    2
  )->'reasonCodes' ? 'duplicate_source_identity',
  'dubbele naam plus DOB in één CSV blokkeert in plaats van gokken'
);

select pg_temp.prepare_identity_analysis(
  'de500000-0000-4000-8000-000000000005',
  'de600000-0000-4000-8000-000000000005',
  'de700000-0000-4000-8000-000000000005',
  jsonb_build_array(jsonb_build_object(
    'first_name', 'Chris',
    'last_name', 'Dubbel',
    'email', 'derde-ouder@example.test',
    'team', 'JO11-3',
    'date_of_birth', '2016-03-03'
  ))
);
select ok(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000005',
    2
  )->'reasonCodes' ? 'identity_ambiguous',
  'meerdere bestaande leden met dezelfde naam en DOB zijn een blokkend conflict'
);

select pg_temp.prepare_identity_analysis(
  'de500000-0000-4000-8000-000000000006',
  'de600000-0000-4000-8000-000000000006',
  'de700000-0000-4000-8000-000000000006',
  jsonb_build_array(jsonb_build_object(
    'first_name', 'Alex',
    'last_name', 'Bestaand',
    'email', 'ander-ouder@example.test',
    'team', 'JO15-1',
    'date_of_birth', '2012-01-01'
  ))
);
select ok(
  private.dynamic_import_analyze_row(
    'de700000-0000-4000-8000-000000000006',
    2
  )->'reasonCodes' ? 'email_identity_mismatch',
  'een afwijkende oudermail bij naam plus DOB vraagt expliciete beoordeling'
);

select is(
  private.dynamic_import_selected_row_valid(
    (
      select mapping
      from app.import_mapping_revisions
      where id = 'de600000-0000-4000-8000-000000000001'
    ),
    jsonb_build_object(
      'sourceRow', 2,
      'fields', jsonb_build_object(
        'external_member_id', 'FORMULA-1',
        'first_name', '=HYPERLINK',
        'last_name', 'Onveilig',
        'team', 'JO9-1'
      ),
      'sizes', '{}'::jsonb,
      'errors', '[]'::jsonb
    ),
    2
  ),
  false,
  'database accepteert geen formuleachtige geselecteerde importwaarde'
);

select * from finish();
rollback;
