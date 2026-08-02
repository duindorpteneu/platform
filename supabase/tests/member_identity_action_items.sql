begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('d0000000-0000-4000-8000-000000000001', 'Actiebeheer', 'beheerder'),
  ('d0000000-0000-4000-8000-000000000002', 'Actiecommissie', 'kledingcommissie'),
  ('d0000000-0000-4000-8000-000000000003', 'Actieuitgifte', 'uitgifte');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('d1000000-0000-4000-8000-000000000001', '2047/2048 identiteit', 10000, 'open');
update app.app_settings
set active_season_id = 'd1000000-0000-4000-8000-000000000001'
where id = true;

select ok(
  (
    select is_nullable = 'YES'
    from information_schema.columns
    where table_schema = 'app'
      and table_name = 'members'
      and column_name = 'relation_number'
  ),
  'Sportlink-relatienummer is werkelijk optioneel'
);
select ok(
  (
    select is_nullable = 'YES'
    from information_schema.columns
    where table_schema = 'app'
      and table_name = 'members'
      and column_name = 'email'
  ),
  'ouder-e-mail is werkelijk optioneel'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.normalize_member_optional_identity()',
    'EXECUTE'
  ),
  'identitynormalisatie is uitsluitend een database-triggergrens'
);

insert into app.members(
  id, relation_number, first_name, last_name, email, team, active_for_season
) values
  ('d2000000-0000-4000-8000-000000000001', null, 'Noa', 'Zondernummer', null, 'JO13-1', true),
  ('d2000000-0000-4000-8000-000000000002', null, 'Mila', 'Zondernummer', ' ONGELDIG-ADRES ', 'MO13-1', true);

select is(
  (
    select email
    from app.members
    where id = 'd2000000-0000-4000-8000-000000000002'
  ),
  'ongeldig-adres',
  'ouderadressen worden canoniek opgeslagen maar blijven valideerbare importconflicten'
);

select is(
  (
    select count(*)
    from app.member_external_identities
    where member_id in (
      'd2000000-0000-4000-8000-000000000001',
      'd2000000-0000-4000-8000-000000000002'
    )
  ),
  0::bigint,
  'ontbrekende externe IDs krijgen geen placeholderidentiteit'
);
select is(
  (
    select count(*)
    from private.member_sensitive_identity
    where member_id in (
      'd2000000-0000-4000-8000-000000000001',
      'd2000000-0000-4000-8000-000000000002'
    )
  ),
  2::bigint,
  'iedere nieuwe lididentiteit krijgt wel een private DOB-shell'
);
select is(
  (
    select count(*)
    from app.member_seasons
    where season_id = 'd1000000-0000-4000-8000-000000000001'
      and member_id in (
        'd2000000-0000-4000-8000-000000000001',
        'd2000000-0000-4000-8000-000000000002'
      )
      and reconciliation_status = 'resolved'
  ),
  2::bigint,
  'compatibilitytrigger maakt expliciete actuele lid-seizoenen'
);

update app.members
set team = 'JO14-1', active_for_season = false
where id = 'd2000000-0000-4000-8000-000000000001';
select is(
  (
    select team_name || ':' || participation_status::text
    from app.member_seasons
    where member_id = 'd2000000-0000-4000-8000-000000000001'
      and season_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  'JO14-1:inactive',
  'bestaand actueel lid-seizoen wordt null-safe bijgewerkt'
);

update app.members
set relation_number = 'SL-2048-1'
where id = 'd2000000-0000-4000-8000-000000000001';
select is(
  (
    select external_id_normalized
    from app.member_external_identities
    where member_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'SL-2048-1',
  'eerste expliciete Sportlink-ID wordt exact gekoppeld'
);
select throws_ok(
  $$update app.members
    set relation_number = 'SL-2048-ANDERS'
    where id = 'd2000000-0000-4000-8000-000000000001'$$,
  '23505',
  'MEMBER_EXTERNAL_IDENTITY_CHANGE_REQUIRES_WORKFLOW',
  'een bestaand extern ID wordt nooit stil herverdeeld'
);

select has_table('app', 'action_items', 'uniforme action-itemledger bestaat');
select ok(
  not has_table_privilege('authenticated', 'app.action_items', 'INSERT'),
  'staff kan action items niet rechtstreeks aanmaken'
);
select ok(
  not has_table_privilege('service_role', 'app.action_items', 'SELECT'),
  'service-role krijgt geen brede action-itemread'
);
select ok(
  not has_function_privilege(
    'service_role',
    'private.open_action_item(text,uuid,text,uuid,text,uuid,text,app.action_item_severity,app.action_item_visibility,text,jsonb,timestamptz)',
    'EXECUTE'
  ),
  'action-itemhelper is alleen intern binnen security-definertransacties'
);

create temporary table opened_actions as
select
  private.open_action_item(
    'size_other',
    'd1000000-0000-4000-8000-000000000001',
    'member_season',
    (select id from app.member_seasons
      where member_id = 'd2000000-0000-4000-8000-000000000001'
        and season_id = 'd1000000-0000-4000-8000-000000000001'),
    'import_batch',
    null,
    encode(extensions.digest(
      'size_other:d2000000-0000-4000-8000-000000000001:c200',
      'sha256'
    ), 'hex'),
    'warning',
    'operations',
    'size_value_unknown',
    jsonb_build_object('articleId', 'c2000000-0000-4000-8000-000000000001', 'sourceRow', 2),
    null
  ) first_id,
  private.open_action_item(
    'payment_conflict',
    'd1000000-0000-4000-8000-000000000001',
    'member_season',
    (select id from app.member_seasons
      where member_id = 'd2000000-0000-4000-8000-000000000002'
        and season_id = 'd1000000-0000-4000-8000-000000000001'),
    'import_batch',
    null,
    encode(extensions.digest(
      'payment_conflict:d2000000-0000-4000-8000-000000000002',
      'sha256'
    ), 'hex'),
    'critical',
    'admin_only',
    'payment_state_conflict',
    jsonb_build_object('sourceRow', 3),
    null
  ) second_id;
grant select on opened_actions to authenticated;

select is(
  private.open_action_item(
    'size_other',
    'd1000000-0000-4000-8000-000000000001',
    'member_season',
    (select id from app.member_seasons
      where member_id = 'd2000000-0000-4000-8000-000000000001'
        and season_id = 'd1000000-0000-4000-8000-000000000001'),
    'import_batch',
    null,
    encode(extensions.digest(
      'size_other:d2000000-0000-4000-8000-000000000001:c200',
      'sha256'
    ), 'hex'),
    'warning',
    'operations',
    'size_value_unknown',
    jsonb_build_object('articleId', 'c2000000-0000-4000-8000-000000000001', 'sourceRow', 2),
    null
  ),
  (select first_id from opened_actions),
  'dezelfde tekort-/conflictepisode dedupliceert naar één actiepunt'
);
select throws_ok(
  $$select private.open_action_item(
    'size_other',
    'd1000000-0000-4000-8000-000000000001',
    'member_season',
    (select id from app.member_seasons limit 1),
    'import_batch',
    null,
    'size_other:unsafe',
    'warning',
    'operations',
    'size_value_unknown',
    '{}'::jsonb,
    null
  )$$,
  '22023',
  'ACTION_ITEM_INPUT_INVALID',
  'een leesbare dedupe-key wordt geweigerd'
);
select throws_ok(
  $$select private.open_action_item(
    'size_other',
    'd1000000-0000-4000-8000-000000000001',
    'member_season',
    (select id from app.member_seasons limit 1),
    'import_batch',
    null,
    encode(extensions.digest('unsafe-context', 'sha256'), 'hex'),
    'warning',
    'operations',
    'size_value_unknown',
    '{"articleId":"ouder@example.invalid"}'::jsonb,
    null
  )$$,
  '22023',
  'ACTION_ITEM_INPUT_INVALID',
  'PII in een toegestane contextkey wordt eveneens geweigerd'
);
select throws_ok(
  $$select private.open_action_item(
    'size_other',
    'd1000000-0000-4000-8000-000000000001',
    'member_season',
    (select id from app.member_seasons
      where member_id = 'd2000000-0000-4000-8000-000000000002'
        and season_id = 'd1000000-0000-4000-8000-000000000001'),
    'import_batch',
    null,
    encode(extensions.digest(
      'size_other:d2000000-0000-4000-8000-000000000001:c200',
      'sha256'
    ), 'hex'),
    'warning',
    'operations',
    'size_value_unknown',
    '{}'::jsonb,
    null
  )$$,
  '23505',
  'ACTION_ITEM_DEDUPE_COLLISION',
  'dezelfde dedupe-digest kan nooit een ander object stil samenvoegen'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select is(
  (select count(*) from app.action_items),
  1::bigint,
  'kledingcommissie ziet uitsluitend operationele actiepunten'
);
select throws_ok(
  $$select app.resolve_action_item(
    (select second_id from opened_actions),
    'dismissed',
    'Niet van toepassing',
    null
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan admin-only conflict niet sluiten'
);
select is(
  app.resolve_action_item(
    (select first_id from opened_actions),
    'resolved',
    'Echte variant gekoppeld',
    null
  )->>'status',
  'resolved',
  'kledingcommissie kan een operationeel actiepunt met reden oplossen'
);
reset role;

create temporary table reopened_action as
select private.open_action_item(
  'size_other',
  'd1000000-0000-4000-8000-000000000001',
  'member_season',
  (select id from app.member_seasons
    where member_id = 'd2000000-0000-4000-8000-000000000001'
      and season_id = 'd1000000-0000-4000-8000-000000000001'),
  'import_batch',
  null,
  encode(extensions.digest(
    'size_other:d2000000-0000-4000-8000-000000000001:c200',
    'sha256'
  ), 'hex'),
  'warning',
  'operations',
  'size_value_unknown',
  jsonb_build_object(
    'articleId',
    'c2000000-0000-4000-8000-000000000001',
    'sourceRow',
    4
  ),
  null
) id;
grant select on reopened_action to authenticated;
select isnt(
  (select id from reopened_action),
  (select first_id from opened_actions),
  'een aantoonbaar herstelde en teruggekeerde toestand opent een nieuwe episode'
);
select is(
  (
    select episode
    from app.action_items
    where id = (select id from reopened_action)
  ),
  2,
  'de database alloceert de volgende episode transactioneel'
);
select is(
  (
    select count(*)
    from app.action_items
    where type = 'size_other'
      and season_id = 'd1000000-0000-4000-8000-000000000001'
      and status in ('open', 'in_progress')
  ),
  1::bigint,
  'per toestand bestaat maximaal één actieve episode'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
select is(
  (select count(*) from app.action_items),
  0::bigint,
  'uitgifte ziet geen actiepunten'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  (select count(*) from app.action_items),
  3::bigint,
  'beheerder ziet operationele en admin-only actiepunten'
);
select is(
  (
    select item->>'emailState'
    from jsonb_array_elements(
      app.get_parent_access_workspace(
        'd1000000-0000-4000-8000-000000000001',
        'Noa',
        0,
        100
      )->'members'
    ) item
    limit 1
  ),
  'missing',
  'ontbrekend ouderadres is expliciet missing en nooit ongeldig'
);
select throws_ok(
  $$select app.resolve_action_item(
    (select second_id from opened_actions),
    'dismissed',
    'x',
    null
  )$$,
  '22023',
  'ACTION_ITEM_RESOLUTION_INVALID',
  'afwijzen vereist een inhoudelijke reden'
);
reset role;

select ok(
  not exists(
    select 1
    from app.audit_logs
    where entity_type = 'action_item'
      and metadata::text ~* 'Noa|Mila|example|SL-2048'
  ),
  'action-itemaudit bevat geen naam, e-mail of extern ID'
);

select * from finish();
rollback;
