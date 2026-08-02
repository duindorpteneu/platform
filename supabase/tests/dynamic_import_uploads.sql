begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('b0000000-0000-4000-8000-000000000001', 'Importbeheer', 'beheerder'),
  ('b0000000-0000-4000-8000-000000000002', 'Importcommissie', 'kledingcommissie'),
  ('b0000000-0000-4000-8000-000000000003', 'Importuitgifte', 'uitgifte');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('b1000000-0000-4000-8000-000000000001', '2044/2045 import', 10000, 'open');
update app.app_settings
set active_season_id = 'b1000000-0000-4000-8000-000000000001'
where id = true;

select has_table('private', 'import_staging_payloads', 'versleutelde raw-importstaging bestaat');
select has_column('app', 'import_batches', 'dynamic_status', 'importbatch heeft afzonderlijke dynamische statusas');
select ok(
  not has_table_privilege('authenticated', 'private.import_staging_payloads', 'SELECT'),
  'authenticated kan ciphertext niet rechtstreeks lezen'
);
select ok(
  not has_table_privilege('service_role', 'private.import_staging_payloads', 'SELECT'),
  'ook service_role leest staging uitsluitend via de smalle RPC'
);
select ok(
  not has_function_privilege('authenticated', 'app.read_dynamic_import_payload(uuid)', 'EXECUTE'),
  'payload-read is niet beschikbaar voor applicatierollen'
);
select ok(
  has_function_privilege('service_role', 'app.read_dynamic_import_payload(uuid)', 'EXECUTE'),
  'payload-read is alleen service-role'
);
select ok(
  has_function_privilege('service_role', 'app.cleanup_expired_security_data_v2(timestamptz)', 'EXECUTE'),
  'uitgebreide retentie is service-role'
);
select ok(
  has_function_privilege('service_role', 'app.get_operational_health_v3()', 'EXECUTE'),
  'health-v3 is service-role'
);
select ok(
  not has_function_privilege('authenticated', 'app.assert_dynamic_import_staging_key(text)', 'EXECUTE'),
  'applicatierollen kunnen de deploymentsleutelgate niet aanroepen'
);
select ok(
  has_function_privilege('service_role', 'app.assert_dynamic_import_staging_key(text)', 'EXECUTE'),
  'sleutelrotatiegate is uitsluitend voor service-role'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_workspace()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder zonder AAL2 kan de importworkspace niet openen'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_dynamic_import_workspace()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan de dynamische import niet openen'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.get_dynamic_import_workspace()->>'featureEnabled',
  'false',
  'databasefeaturepoort staat standaard veilig uit'
);
select throws_ok(
  $$select app.create_dynamic_import_upload(
    'b2000000-0000-4000-8000-000000000001',
    'b3000000-0000-4000-8000-000000000001',
    'b1000000-0000-4000-8000-000000000001',
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
  )$$,
  '55000',
  'DYNAMIC_IMPORT_DISABLED',
  'upload kan niet langs een uitgeschakelde DB-featurepoort'
);

reset role;
update app.release_feature_flags
set enabled = true
where key = 'dynamic_import_v2';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_sportlink_import_summary(
    '[{"relation_number":"DSV-LEGACY","first_name":"Noa","insertion":null,"last_name":"Jansen","email":"ouder@example.invalid","team":"JO13-1","active_for_season":true}]'::jsonb
  )$$,
  '55000',
  'LEGACY_IMPORT_DISABLED',
  'legacy-preview-RPC sluit zodra de databasefeaturepoort actief is'
);
select throws_ok(
  $$select app.commit_sportlink_import(
    'legacy.csv',
    repeat('a', 64),
    '{}'::jsonb,
    '[{"relation_number":"DSV-LEGACY","first_name":"Noa","insertion":null,"last_name":"Jansen","email":"ouder@example.invalid","team":"JO13-1","active_for_season":true}]'::jsonb
  )$$,
  '55000',
  'LEGACY_IMPORT_DISABLED',
  'legacy-commit-RPC kan de v2-cutover niet omzeilen'
);
create temporary table first_upload as
select app.create_dynamic_import_upload(
  'b2000000-0000-4000-8000-000000000001',
  'b3000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000001',
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
  'b4000000-0000-4000-8000-000000000001'
) result;
select is(
  (select result->>'status' from first_upload),
  'uploaded',
  'beheerder stageert een upload'
);
select is(
  (select result->>'reused' from first_upload),
  'false',
  'eerste upload is nieuw'
);
reset role;
select is(
  (select count(*) from private.import_staging_payloads),
  1::bigint,
  'uitsluitend ciphertext wordt duurzaam gestaged'
);
select is(
  (select dynamic_status::text from app.import_batches
    where id = 'b2000000-0000-4000-8000-000000000001'),
  'uploaded',
  'batchmetadata en raw-payload delen één status'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select count(*)
    from app.import_batches
    where id = 'b2000000-0000-4000-8000-000000000001'$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder zonder AAL2 kan dynamische importbatchmetadata niet lezen'
);
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select is(
  (
    select count(*)
    from app.import_batches
    where id = 'b2000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'kledingcommissie kan dynamische importbatchmetadata niet lezen'
);
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  (
    select count(*)
    from app.import_batches
    where id = 'b2000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'beheerder kan eigen dynamische importbatchmetadata lezen'
);
reset role;
select ok(
  not exists(
    select 1
    from app.audit_logs
    where entity_id = 'b2000000-0000-4000-8000-000000000001'
      and metadata::text ~* 'leden.csv|aaaaaaaaaaaaaaaa'
  ),
  'audit bevat geen bestandsnaam, checksum of bronwaarde'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.create_dynamic_import_upload(
    'b2000000-0000-4000-8000-000000000099',
    'b3000000-0000-4000-8000-000000000001',
    'b1000000-0000-4000-8000-000000000001',
    'leden.csv',
    repeat('a', 64),
    ';',
    120,
    2,
    3,
    repeat('B', 24),
    repeat('B', 16),
    1,
    repeat('f', 64),
    24,
    null
  )->>'batchId',
  'b2000000-0000-4000-8000-000000000001',
  'retry met dezelfde sleutel en bytes hergebruikt exact dezelfde batch'
);
select throws_ok(
  $$select app.create_dynamic_import_upload(
    'b2000000-0000-4000-8000-000000000099',
    'b3000000-0000-4000-8000-000000000001',
    'b1000000-0000-4000-8000-000000000001',
    'leden.csv',
    repeat('b', 64),
    ';',
    120,
    2,
    3,
    repeat('B', 24),
    repeat('B', 16),
    1,
    repeat('f', 64),
    24,
    null
  )$$,
  '23505',
  'DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT',
  'dezelfde herhaalsleutel kan nooit andere bytes aanwijzen'
);
select throws_ok(
  $$select app.read_dynamic_import_payload('b2000000-0000-4000-8000-000000000001')$$,
  '42501',
  'permission denied for function read_dynamic_import_payload',
  'beheerder leest ciphertext niet via de browserrol'
);
reset role;

set local role service_role;
select is(
  app.assert_dynamic_import_staging_key(repeat('f', 64))->>'pending',
  '1',
  'dezelfde importstaging-sleutel is veilig voor een volgende release'
);
select throws_ok(
  $$select app.assert_dynamic_import_staging_key(repeat('e', 64))$$,
  '55000',
  'IMPORT_STAGING_KEY_ROTATION_BLOCKED',
  'sleutelrotatie blokkeert zolang een actieve upload de oude sleutel nodig heeft'
);
select throws_ok(
  $$select app.assert_dynamic_import_staging_key(null)$$,
  '55000',
  'IMPORT_STAGING_KEY_ROTATION_BLOCKED',
  'de staging-sleutel kan niet worden verwijderd met actieve uploads'
);
select is(
  app.read_dynamic_import_payload('b2000000-0000-4000-8000-000000000001')->>'ciphertext',
  repeat('A', 24),
  'service-worker kan alleen via de smalle RPC versleutelde data ophalen'
);
select is(
  (
    select count(*)::integer
    from jsonb_object_keys(app.cleanup_expired_security_data(timezone('utc', now())))
  ),
  4::integer,
  'legacy-retentiecontract blijft exact rollbackcompatibel'
);
select is(
  (
    select count(*)::integer
    from jsonb_object_keys(app.cleanup_expired_security_data_v2(timezone('utc', now())))
  ),
  5::integer,
  'retentie-v2 voegt uitsluitend de importtelling toe'
);
reset role;

update private.import_staging_payloads
set created_at = timezone('utc', now()) - interval '2 hours',
    expires_at = timezone('utc', now()) - interval '1 second'
where batch_id = 'b2000000-0000-4000-8000-000000000001';
set local role service_role;
select is(
  app.get_operational_health_v3() #>> '{importStaging,expired}',
  '1',
  'health signaleert verlopen raw-staging zonder PII'
);
select is(
  app.cleanup_expired_security_data_v2(timezone('utc', now()))->>'importStaging',
  '1',
  'retentie verwijdert exact de verlopen payload'
);
reset role;
select is(
  (select count(*) from private.import_staging_payloads),
  0::bigint,
  'verlopen ciphertext is werkelijk verwijderd'
);
select is(
  (select dynamic_status::text from app.import_batches
    where id = 'b2000000-0000-4000-8000-000000000001'),
  'expired',
  'duurzame batchmetadata bewaart alleen de verlopen status'
);

select * from finish();
rollback;
