begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('f3000000-0000-4000-8000-000000000001', 'Actiebeheer', 'beheerder'),
  ('f3000000-0000-4000-8000-000000000002', 'Actiecommissie', 'kledingcommissie'),
  ('f3000000-0000-4000-8000-000000000003', 'Actieuitgifte', 'uitgifte');

insert into app.seasons(id, name, default_amount_cents, status) values
  ('f3100000-0000-4000-8000-000000000001', '2055/2056 actiebeheer', 10000, 'open');
update app.app_settings
set active_season_id = 'f3100000-0000-4000-8000-000000000001'
where id = true;

select has_column(
  'app',
  'action_items',
  'revision',
  'actiepunten hebben een expliciete optimistic-concurrencyrevisie'
);
select has_column(
  'app',
  'action_items',
  'assigned_at',
  'toewijzing heeft een tijdstempel'
);
select has_column(
  'app',
  'action_items',
  'started_at',
  'starten heeft een tijdstempel'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.get_action_item_workspace_v2(uuid,app.action_item_status,app.action_item_severity,uuid,boolean,integer,integer)',
    'EXECUTE'
  ),
  'geauthenticeerde staff kan de begrensde workspace-RPC uitvoeren'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.resolve_action_item_v2(uuid,integer,text,uuid)',
    'EXECUTE'
  ),
  'legacy vrije-tekst-resolve is niet meer uitvoerbaar'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.resolve_action_item_v3(uuid,integer,text,uuid)',
    'EXECUTE'
  ),
  'domein-only resolvecontract blijft server-side afgedwongen'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.assign_action_item(uuid,integer,uuid,uuid)',
    'EXECUTE'
  ),
  'geauthenticeerde staff kan alleen via de assign-RPC muteren'
);
select ok(
  not has_table_privilege('authenticated', 'app.action_items', 'UPDATE'),
  'rechtstreeks bijwerken blijft verboden'
);
select ok(
  not has_table_privilege('authenticated', 'app.action_items', 'DELETE'),
  'actiepunten kunnen niet destructief worden verwijderd'
);

create temporary table managed_actions as
select
  private.open_action_item(
    'size_other',
    'f3100000-0000-4000-8000-000000000001',
    'member_season',
    'f3200000-0000-4000-8000-000000000001',
    'size_selection',
    null,
    encode(extensions.digest('managed-operation-action', 'sha256'), 'hex'),
    'warning',
    'operations',
    'size_value_unknown',
    jsonb_build_object(
      'memberSeasonId',
      'f3200000-0000-4000-8000-000000000001'
    ),
    timezone('utc', now()) + interval '2 days'
  ) operation_id,
  private.open_action_item(
    'payment_conflict',
    'f3100000-0000-4000-8000-000000000001',
    'package_order',
    'f3300000-0000-4000-8000-000000000001',
    'payment',
    null,
    encode(extensions.digest('managed-admin-action', 'sha256'), 'hex'),
    'critical',
    'admin_only',
    'payment_state_conflict',
    jsonb_build_object(
      'packageOrderId',
      'f3300000-0000-4000-8000-000000000001'
    ),
    null
  ) admin_id,
  private.open_action_item(
    'low_stock',
    'f3100000-0000-4000-8000-000000000001',
    'article_variant',
    'f3400000-0000-4000-8000-000000000001',
    'article_variant',
    'f3400000-0000-4000-8000-000000000001',
    encode(extensions.digest('managed-producer-action', 'sha256'), 'hex'),
    'info',
    'operations',
    'stock_below_threshold',
    jsonb_build_object(
      'variantId',
      'f3400000-0000-4000-8000-000000000001',
      'available',
      8
    ),
    null
  ) producer_id;
grant select on managed_actions to authenticated;

select is(
  (
    select revision
    from app.action_items
    where id = (select operation_id from managed_actions)
  ),
  1,
  'nieuwe actiepunten starten op revisie één'
);

select is(
  private.open_action_item(
    'low_stock',
    'f3100000-0000-4000-8000-000000000001',
    'article_variant',
    'f3400000-0000-4000-8000-000000000001',
    'article_variant',
    'f3400000-0000-4000-8000-000000000001',
    encode(extensions.digest('managed-producer-action', 'sha256'), 'hex'),
    'warning',
    'operations',
    'stock_below_threshold',
    jsonb_build_object(
      'variantId',
      'f3400000-0000-4000-8000-000000000001',
      'available',
      7
    ),
    null
  ),
  (select producer_id from managed_actions),
  'een domeinproducer hergebruikt de actieve episode'
);
select is(
  (
    select revision
    from app.action_items
    where id = (select producer_id from managed_actions)
  ),
  2,
  'een gewijzigde producerwaarneming verhoogt eveneens de revisie'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"f3000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);

select is(
  (select count(*) from app.action_items),
  2::bigint,
  'kledingcommissie leest via RLS alleen operationele actiepunten'
);
select is(
  jsonb_array_length(
    app.get_action_item_workspace_v2(
      'f3100000-0000-4000-8000-000000000001',
      null,
      null,
      null,
      false,
      0,
      50
    )->'items'
  ),
  2,
  'workspace past dezelfde operationele zichtbaarheid toe'
);
select ok(
  not exists(
    select 1
    from jsonb_array_elements(
      app.get_action_item_workspace_v2(
        'f3100000-0000-4000-8000-000000000001',
        null,
        null,
        null,
        false,
        0,
        50
      )->'items'
    ) item
    where (item->'actions'->>'canResolve')::boolean
  ),
  'workspace biedt geen generieke vrije-tekst-resolve aan'
);
select is(
  jsonb_array_length(
    app.get_action_item_workspace_v2(
      'f3100000-0000-4000-8000-000000000001',
      null,
      null,
      null,
      false,
      0,
      50
    )->'ownerOptions'
  ),
  2,
  'alleen beheerder en kledingcommissie zijn geldige eigenaren'
);
select is(
  app.assign_action_item(
    (select operation_id from managed_actions),
    1,
    'f3000000-0000-4000-8000-000000000002',
    'f3500000-0000-4000-8000-000000000001'
  )->>'revision',
  '2',
  'kledingcommissie wijst een operationeel actiepunt revision-checked toe'
);
select throws_ok(
  $$select app.assign_action_item(
    (select operation_id from managed_actions),
    1,
    'f3000000-0000-4000-8000-000000000001',
    null
  )$$,
  '40001',
  'ACTION_ITEM_REVISION_CONFLICT',
  'een stale toewijzing wordt geblokkeerd'
);
select throws_ok(
  $$select app.assign_action_item(
    (select operation_id from managed_actions),
    2,
    'f3000000-0000-4000-8000-000000000003',
    null
  )$$,
  '23514',
  'ACTION_ITEM_OWNER_INVALID',
  'uitgifte kan geen actiepunteigenaar worden'
);
select is(
  app.start_action_item(
    (select operation_id from managed_actions),
    2,
    null
  )->>'status',
  'in_progress',
  'de toegewezen eigenaar kan het actiepunt starten'
);
select throws_ok(
  $$select app.assign_action_item(
    (select operation_id from managed_actions),
    3,
    null,
    null
  )$$,
  '23514',
  'ACTION_ITEM_ACTIVE_OWNER_REQUIRED',
  'een gestart actiepunt kan niet eigenaarloos worden gemaakt'
);
select throws_ok(
  $$select app.dismiss_action_item(
    (select operation_id from managed_actions),
    3,
    'x',
    null
  )$$,
  '22023',
  'ACTION_ITEM_RESOLUTION_INVALID',
  'afwijzen vereist een inhoudelijke reden'
);
select is(
  app.dismiss_action_item(
    (select operation_id from managed_actions),
    3,
    'Bewust afgewezen na operationele controle',
    'f3500000-0000-4000-8000-000000000002'
  )->>'revision',
  '4',
  'afwijzen sluit exact de verwachte revisie'
);
select is(
  (
    select status::text || ':' || resolution_source
    from app.action_items
    where id = (select operation_id from managed_actions)
  ),
  'dismissed:staff',
  'de afwijzing blijft als niet-destructief stafffeit bewaard'
);
select throws_ok(
  $$select app.assign_action_item(
    (select admin_id from managed_actions),
    1,
    'f3000000-0000-4000-8000-000000000002',
    null
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan een admin-only actiepunt ook via RPC niet benaderen'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"f3000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  (select count(*) from app.action_items),
  3::bigint,
  'beheerder leest alle zichtbare actiepunten in het seizoen'
);
select throws_ok(
  $$select app.assign_action_item(
    (select admin_id from managed_actions),
    1,
    'f3000000-0000-4000-8000-000000000002',
    null
  )$$,
  '23514',
  'ACTION_ITEM_OWNER_INVALID',
  'admin-only werk kan niet aan kledingcommissie worden toegewezen'
);
select is(
  app.assign_action_item(
    (select admin_id from managed_actions),
    1,
    'f3000000-0000-4000-8000-000000000001',
    null
  )->>'revision',
  '2',
  'beheerder kan admin-only werk veilig aan een beheerder toewijzen'
);
select throws_ok(
  $$select app.resolve_action_item_v3(
    (select admin_id from managed_actions),
    2,
    'Betaalconflict gecontroleerd en hersteld',
    null
  )$$,
  '23514',
  'ACTION_ITEM_DOMAIN_REPAIR_REQUIRED',
  'vrije tekst kan een domeinconflict niet vals sluiten'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where entity_type = 'action_item'
      and entity_id in (
        (select operation_id from managed_actions),
        (select admin_id from managed_actions)
      )
      and action in (
        'action_item.assigned',
        'action_item.started',
        'action_item.dismissed'
      )
  ),
  4::bigint,
  'iedere beheertransitie schrijft exact één auditfeit'
);
select ok(
  not exists(
    select 1
    from app.audit_logs
    where entity_type = 'action_item'
      and metadata::text like '%Bewust afgewezen%'
  ),
  'vrije redenvelden worden niet naar auditmetadata gedupliceerd'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"f3000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.get_action_item_workspace_v2(
    'f3100000-0000-4000-8000-000000000001',
    null,
    null,
    null,
    false,
    0,
    50
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan de actiepuntenworkspace niet openen'
);
reset role;

select * from finish();
rollback;
