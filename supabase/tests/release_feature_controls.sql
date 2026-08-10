begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'fa000000-0000-4000-8000-000000000001',
  'Releasebeheerder',
  'beheerder'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"fa000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);

select is(
  app.get_release_feature_controls_v1() #>> '{memberSeasons,ready}',
  'true',
  'lege gereconcilieerde staging is gereed voor member-season cutover'
);
select lives_ok(
  format(
    'select app.activate_release_feature_v1(%L,%L,%L,null)',
    'member_seasons_v2',
    app.get_release_feature_controls_v1()->>'revision',
    'Gecontroleerde activatie'
  ),
  'beheerder activeert member-season met exacte preflight'
);
select is(
  (select enabled::text from app.release_feature_flags
   where key = 'member_seasons_v2'),
  'true',
  'member-seasonflag is actief'
);
select lives_ok(
  format(
    'select app.activate_release_feature_v1(%L,%L,%L,null)',
    'package_orders_v2',
    app.get_release_feature_controls_v1()->>'revision',
    'Gecontroleerde activatie'
  ),
  'pakketorders worden pas na member-season geactiveerd'
);
select lives_ok(
  format(
    'select app.activate_release_feature_v1(%L,%L,%L,null)',
    'dynamic_import_v2',
    app.get_release_feature_controls_v1()->>'revision',
    'Gecontroleerde activatie'
  ),
  'dynamische import krijgt een duurzame cutover'
);
select ok(
  (app.get_release_feature_controls_v1()
    #>> '{dynamicImport,cutoverActive}')::boolean,
  'importcutover blijft duurzaam geregistreerd'
);
select lives_ok(
  $$select app.pause_release_feature_v1(
    'dynamic_import_v2',
    'Operationele noodpauze',
    null
  )$$,
  'beheerder kan import operationeel pauzeren'
);
select ok(
  (app.get_release_feature_controls_v1()
    #>> '{dynamicImport,cutoverActive}')::boolean
  and not (app.get_release_feature_controls_v1()
    #>> '{dynamicImport,enabled}')::boolean,
  'pauze wist de cutover niet'
);
select throws_ok(
  $$select app.activate_release_feature_v1(
    'scanner_pwa_v2',
    repeat('a',64),
    'Niet toegestaan',
    null
  )$$,
  '22023',
  'RELEASE_FEATURE_INPUT_INVALID',
  'gespecialiseerde QR/scannerpoort kan niet generiek worden omzeild'
);
select ok(
  (select count(*) from app.audit_logs
   where actor_user_id = 'fa000000-0000-4000-8000-000000000001'
     and action in (
       'release.feature.activated',
       'release.feature.paused'
     )) >= 4,
  'alle activaties en pauze zijn append-only geaudit'
);

select * from finish();
rollback;
