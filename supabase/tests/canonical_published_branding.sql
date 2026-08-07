begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(
  auth_user_id,
  display_name,
  role,
  active
) values (
  'b4400000-0000-4000-8000-000000000001',
  'Brandingbeheer',
  'beheerder',
  true
);
select set_config(
  'request.jwt.claims',
  '{"sub":"b4400000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);

select is(
  private.branding_projection_blocker_count_v1(),
  0,
  'de migratie backfillt app_settings uit de gepubliceerde branding'
);
select is(
  app.get_settings_workspace_v3()
    #>> '{settings,brandingRevision}',
  '1',
  'de instellingenworkspace toont de gepubliceerde brandingrevisie'
);
select is(
  app.get_settings_workspace_v3()
    #>> '{settings,pickupLocation}',
  'Free-Kick Sport, De Savornin Lohmanplein 45, 2566 AE Den Haag',
  'instellingen en uitgifte lezen exact dezelfde afhaallocatie'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.app_settings',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'app.app_settings',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'app.app_settings',
    'delete'
  ),
  'authenticated kan app_settings niet buiten geautoriseerde RPCs muteren'
);

select lives_ok(
  $$select app.update_settings_v3(
    null,
    '[]'::jsonb,
    false,
    false,
    null
  )$$,
  'operationele settingsmutatie laat branding intact'
);
select is(
  private.branding_projection_blocker_count_v1(),
  0,
  'operationele settingsmutatie veroorzaakt geen brandingdrift'
);
select throws_ok(
  $$select app.update_settings_v2(
    'ander@example.invalid',
    'Houtrustlaan 1',
    '2566 ZW',
    'Den Haag',
    true,
    'Free-Kick Sport',
    'De Savornin Lohmanplein 45',
    '2566 AE',
    'Den Haag',
    null,
    '[]'::jsonb,
    false,
    false,
    null
  )$$,
  '22023',
  'SETTINGS_BRANDING_MANAGED_SEPARATELY',
  'de rollbackcompatibele v2-RPC kan branding niet meer wijzigen'
);

create temporary table branding_draft as
select app.save_mail_branding_draft_v1(
  null,
  jsonb_build_object(
    'clubName', 'Duindorp SV',
    'logoAssetPath', '/duindorp-sv-logo.png',
    'fromName', 'Kledingcommissie Duindorp SV',
    'fromEmail', 'kleding@duindorpsv.nl',
    'replyToEmail', 'kleding@duindorpsv.nl',
    'contactEmail', 'kleding@duindorpsv.nl',
    'clubAddressLine', 'Houtrustlaan 1',
    'clubPostalCode', '2566 ZW',
    'clubCity', 'Den Haag',
    'pickupName', 'Free-Kick Sport test',
    'pickupAddressLine', 'De Savornin Lohmanplein 45',
    'pickupPostalCode', '2566 AE',
    'pickupCity', 'Den Haag',
    'privacyUrl', 'https://duindorpsv.nl/privacy',
    'primaryColor', '#17418B',
    'secondaryColor', '#0B2E63',
    'accentColor', '#2E69CC',
    'footerText',
      'Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy',
    'contrastValidated', true
  ),
  null
) result;

select is(
  (select pickup_name from app.app_settings where id = true),
  'Free-Kick Sport',
  'een brandingconcept wijzigt de operationele projectie niet'
);
select is(
  app.publish_mail_branding_revision_v2(
    (select (result->>'revisionId')::uuid from branding_draft),
    (select result->>'contentHash' from branding_draft),
    null
  )->>'status',
  'published',
  'publiceren voltooit de nieuwe brandingrevisie'
);
select is(
  (select pickup_name from app.app_settings where id = true),
  'Free-Kick Sport test',
  'publiceren synchroniseert app_settings in dezelfde transactie'
);
select is(
  private.branding_projection_blocker_count_v1(),
  0,
  'publiceren laat geen projectiedrift achter'
);
select is(
  public.get_public_brand_tokens_v1()->>'primaryColor',
  '#17418B',
  'de publieke surface geeft uitsluitend veilige gepubliceerde kleurtokens'
);
select ok(
  has_function_privilege(
    'anon',
    'public.get_public_brand_tokens_v1()',
    'execute'
  ),
  'de publieke brandtokens zijn zonder PII beschikbaar'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"b4400000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  format(
    'select app.publish_mail_branding_revision_v2(%L::uuid,%L,null)',
    (select result->>'revisionId' from branding_draft),
    (select result->>'contentHash' from branding_draft)
  ),
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'branding publiceren blijft beheerder plus MFA'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"b4400000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);

update app.app_settings
set pickup_name = 'Drift test'
where id = true;
select is(
  private.branding_projection_blocker_count_v1(),
  1,
  'een geprivilegieerde afwijking wordt als blocker gedetecteerd'
);
select is(
  app.get_mail_v2_cutover_snapshot_v2()
    #>> '{brandingProjectionBlockers}',
  '1',
  'mailcutover rapporteert brandingdrift'
);
select is(
  app.get_allocation_qr_cutover_snapshot_v2(repeat('0', 64), 1)
    #>> '{brandingProjectionBlockers}',
  '1',
  'QR-cutover rapporteert brandingdrift'
);
select is(
  app.get_email_worker_preflight_v2(
    'Kledingcommissie Duindorp SV',
    'kleding@duindorpsv.nl',
    'kleding@duindorpsv.nl'
  )->>'ready',
  'false',
  'de e-mailworker verstuurt niet bij brandingdrift'
);
select is(
  app.get_operational_health_v12(
    repeat('0', 64),
    1,
    null,
    null
  ) #>> '{brandingProjection,blockers}',
  '1',
  'operationele health maakt brandingdrift releaseblokkerend'
);
select private.sync_published_branding_projection_v1();
select is(
  private.branding_projection_blocker_count_v1(),
  0,
  'de gecontroleerde projectiehelper herstelt drift aantoonbaar'
);

select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.action = 'mail_branding.published'
      and (
        audit.metadata::text ilike '%kleding@duindorpsv.nl%'
        or audit.metadata::text ilike '%Savornin%'
      )
  ),
  'brandingaudit bevat geen contactadres of fysieke locatie'
);

select * from finish();
rollback;
