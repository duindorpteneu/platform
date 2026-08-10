begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(
  auth_user_id,
  display_name,
  role,
  active
) values
  (
    'fa000000-0000-4000-8000-000000000001',
    'Supplier beheerder',
    'beheerder',
    true
  ),
  (
    'fa000000-0000-4000-8000-000000000002',
    'Supplier kledingcommissie',
    'kledingcommissie',
    true
  );

insert into app.seasons(
  id,
  name,
  default_amount_cents,
  status
) values
  (
    'fa100000-0000-4000-8000-000000000001',
    'Supplier 2026-2027',
    1000,
    'open'
  ),
  (
    'fa100000-0000-4000-8000-000000000002',
    'Supplier 2027-2028',
    1000,
    'open'
  );
update app.app_settings
set active_season_id = 'fa100000-0000-4000-8000-000000000001'
where id = true;

insert into app.articles(
  id,
  name,
  code,
  sort_order,
  active
) values (
  'fa200000-0000-4000-8000-000000000001',
  'Supplier broek',
  'SUP-BROEK',
  1,
  true
);
insert into app.article_seasons(article_id, season_id) values (
  'fa200000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000001'
);
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values (
  'fa300000-0000-4000-8000-000000000001',
  'fa200000-0000-4000-8000-000000000001',
  'M',
  'SUP-M',
  1,
  true
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  gender
) values
  (
    'fa400000-0000-4000-8000-000000000001',
    'SUP-001',
    'Mannelijk',
    'Privé',
    'supplier-male@example.invalid',
    'PRIVE-M',
    'male'
  ),
  (
    'fa400000-0000-4000-8000-000000000002',
    'SUP-002',
    'Vrouwelijk',
    'Privé',
    'supplier-female@example.invalid',
    'PRIVE-V',
    'female'
  ),
  (
    'fa400000-0000-4000-8000-000000000003',
    'Onbekend',
    'Conflict',
    'Privé',
    'supplier-unknown@example.invalid',
    'PRIVE-O',
    'unknown'
  ),
  (
    'fa400000-0000-4000-8000-000000000004',
    'Anders',
    'Onbevestigd',
    'Privé',
    'supplier-other@example.invalid',
    'PRIVE-A',
    'other'
  );

insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
) values
  (
    'fa500000-0000-4000-8000-000000000001',
    'fa400000-0000-4000-8000-000000000001',
    'fa100000-0000-4000-8000-000000000001',
    1000
  ),
  (
    'fa500000-0000-4000-8000-000000000002',
    'fa400000-0000-4000-8000-000000000002',
    'fa100000-0000-4000-8000-000000000001',
    1000
  ),
  (
    'fa500000-0000-4000-8000-000000000003',
    'fa400000-0000-4000-8000-000000000003',
    'fa100000-0000-4000-8000-000000000001',
    1000
  ),
  (
    'fa500000-0000-4000-8000-000000000004',
    'fa400000-0000-4000-8000-000000000004',
    'fa100000-0000-4000-8000-000000000001',
    1000
  );

insert into app.order_lines(
  id,
  order_id,
  article_variant_id,
  quantity
) values
  (
    'fa600000-0000-4000-8000-000000000001',
    'fa500000-0000-4000-8000-000000000001',
    'fa300000-0000-4000-8000-000000000001',
    1
  ),
  (
    'fa600000-0000-4000-8000-000000000002',
    'fa500000-0000-4000-8000-000000000002',
    'fa300000-0000-4000-8000-000000000001',
    2
  );

select set_config('app.package_size_internal', 'on', true);
insert into app.member_article_sizes(
  member_id,
  season_id,
  member_season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  raw_value,
  confirmed_at
) values
  (
    'fa400000-0000-4000-8000-000000000001',
    'fa100000-0000-4000-8000-000000000001',
    (
      select id from app.member_seasons
      where member_id = 'fa400000-0000-4000-8000-000000000001'
        and season_id = 'fa100000-0000-4000-8000-000000000001'
    ),
    'fa200000-0000-4000-8000-000000000001',
    'fa300000-0000-4000-8000-000000000001',
    'confirmed',
    'staff',
    null,
    timezone('utc', now())
  ),
  (
    'fa400000-0000-4000-8000-000000000002',
    'fa100000-0000-4000-8000-000000000001',
    (
      select id from app.member_seasons
      where member_id = 'fa400000-0000-4000-8000-000000000002'
        and season_id = 'fa100000-0000-4000-8000-000000000001'
    ),
    'fa200000-0000-4000-8000-000000000001',
    'fa300000-0000-4000-8000-000000000001',
    'confirmed',
    'staff',
    null,
    timezone('utc', now())
  ),
  (
    'fa400000-0000-4000-8000-000000000003',
    'fa100000-0000-4000-8000-000000000001',
    (
      select id from app.member_seasons
      where member_id = 'fa400000-0000-4000-8000-000000000003'
        and season_id = 'fa100000-0000-4000-8000-000000000001'
    ),
    'fa200000-0000-4000-8000-000000000001',
    null,
    'conflict',
    'import',
    'GEHEIME-RUWE-MAAT',
    null
  ),
  (
    'fa400000-0000-4000-8000-000000000004',
    'fa100000-0000-4000-8000-000000000001',
    (
      select id from app.member_seasons
      where member_id = 'fa400000-0000-4000-8000-000000000004'
        and season_id = 'fa100000-0000-4000-8000-000000000001'
    ),
    'fa200000-0000-4000-8000-000000000001',
    'fa300000-0000-4000-8000-000000000001',
    'imported_unconfirmed',
    'import',
    null,
    null
  )
on conflict (member_id, season_id, article_id) do update
set member_season_id = excluded.member_season_id,
    article_variant_id = excluded.article_variant_id,
    selection_status = excluded.selection_status,
    selection_source = excluded.selection_source,
    raw_value = excluded.raw_value,
    member_note = null,
    confirmed_at = excluded.confirmed_at,
    confirmed_by = null,
    updated_at = timezone('utc', now());

insert into app.order_package_snapshot_items(
  snapshot_id,
  article_id,
  article_variant_id,
  quantity,
  product_name_snapshot,
  product_code_snapshot,
  variant_label_snapshot,
  size_snapshot,
  sort_order
)
select
  orders.active_package_snapshot_id,
  'fa200000-0000-4000-8000-000000000001',
  null,
  3,
  'Supplier broek',
  'SUP-BROEK',
  null,
  null,
  1
from app.member_orders orders
where orders.id = 'fa500000-0000-4000-8000-000000000003';
insert into app.order_package_snapshot_items(
  snapshot_id,
  article_id,
  article_variant_id,
  quantity,
  product_name_snapshot,
  product_code_snapshot,
  variant_label_snapshot,
  size_snapshot,
  sort_order
)
select
  orders.active_package_snapshot_id,
  'fa200000-0000-4000-8000-000000000001',
  'fa300000-0000-4000-8000-000000000001',
  4,
  'Supplier broek',
  'SUP-BROEK',
  'M',
  'M',
  1
from app.member_orders orders
where orders.id = 'fa500000-0000-4000-8000-000000000004';
select set_config('app.package_size_internal', 'off', true);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values
  (
    'fa700000-0000-4000-8000-000000000001',
    'fa500000-0000-4000-8000-000000000001',
    'cash',
    'paid',
    1000,
    'supplier-paid-male',
    timezone('utc', now())
  ),
  (
    'fa700000-0000-4000-8000-000000000003',
    'fa500000-0000-4000-8000-000000000003',
    'cash',
    'paid',
    1000,
    'supplier-paid-unknown',
    timezone('utc', now())
  );

update app.article_variants
set active = false
where id = 'fa300000-0000-4000-8000-000000000001';
update app.articles
set active = false
where id = 'fa200000-0000-4000-8000-000000000001';

create temp table admin_session as
select
  payload->>'sessionToken' token,
  encode(
    extensions.digest(payload->>'sessionToken', 'sha256'),
    'hex'
  ) token_hash
from (
  select app.create_staff_app_session_for_user(
    'fa000000-0000-4000-8000-000000000001'
  ) payload
) created;

select is(
  (
    select count(*)::integer
    from pg_enum enum_value
    join pg_type enum_type on enum_type.oid = enum_value.enumtypid
    join pg_namespace namespace on namespace.oid = enum_type.typnamespace
    where namespace.nspname = 'app'
      and enum_type.typname = 'staff_role'
  ),
  3,
  'leverancier voegt geen vierde staffrol toe'
);
select ok(
  not has_table_privilege(
    'anon',
    'private.supplier_planner_principals',
    'SELECT'
  )
  and not has_table_privilege(
    'authenticated',
    'private.supplier_planner_season_grants',
    'SELECT'
  )
  and not has_table_privilege(
    'service_role',
    'private.supplier_planner_sessions',
    'SELECT'
  ),
  'supplier-tabellen zijn default-deny voor alle API-rollen'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.get_supplier_planning_v1(text,uuid,uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.get_supplier_planning_v1(text,uuid,uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.get_supplier_planning_v1(text,uuid,uuid)',
    'EXECUTE'
  ),
  'planning-RPC is uitsluitend via de server-side servicegrens uitvoerbaar'
);

create temp table principal_result as
select app.manage_supplier_planner_v1(
  'create',
  'fa000000-0000-4000-8000-000000000001',
  (select token_hash from admin_session),
  'fa800000-0000-4000-8000-000000000001',
  null,
  'Free-Kick testplanning',
  repeat('a', 64),
  null,
  array['fa100000-0000-4000-8000-000000000001'::uuid]
) payload;

select is(
  payload #>> '{principal,seasonIds,0}',
  'fa100000-0000-4000-8000-000000000001',
  'beheerder verleent één expliciet seizoen'
)
from principal_result;
select ok(
  (payload::text !~* 'access.?token|session.?token'),
  'beheer-RPC retourneert nooit token of tokenhash'
)
from principal_result;
select is(
  app.manage_supplier_planner_v1(
    'create',
    'fa000000-0000-4000-8000-000000000001',
    (select token_hash from admin_session),
    'fa800000-0000-4000-8000-000000000001',
    null,
    'Free-Kick testplanning',
    repeat('a', 64),
    null,
    array['fa100000-0000-4000-8000-000000000001'::uuid]
  )->>'alreadyProcessed',
  'true',
  'identieke beheerrequest replayt exact zonder nieuwe mutatie'
);

create temp table supplier_session as
select app.create_supplier_planner_session_v1(
  repeat('a', 64),
  repeat('b', 64),
  repeat('c', 64)
) payload;

select is(
  app.get_supplier_planner_context_v1(repeat('b', 64))
    #>> '{seasons,0,id}',
  'fa100000-0000-4000-8000-000000000001',
  'leverancierssessie ziet alleen het verleende open seizoen'
);
select is(
  jsonb_array_length(
    app.get_supplier_planner_context_v1(repeat('b', 64))->'seasons'
  ),
  1,
  'niet-verleende open seizoenen blijven buiten de context'
);
select throws_ok(
  $$select app.get_supplier_planning_v1(
    repeat('b', 64),
    'fa100000-0000-4000-8000-000000000002',
    null
  )$$,
  'P0002',
  'SUPPLIER_SEASON_NOT_FOUND',
  'cross-season planning faalt gesloten'
);

create temp table planning_result as
select app.get_supplier_planning_v1(
  repeat('b', 64),
  'fa100000-0000-4000-8000-000000000001',
  'fa900000-0000-4000-8000-000000000001'
) payload;

select is(
  payload #>> '{inventory,0,productCode}',
  'SUP-BROEK',
  'inactief product met open vraag blijft zichtbaar in planning'
)
from planning_result;
select is(
  (payload #>> '{inventory,0,variantActive}')::boolean,
  false,
  'inactieve variant met open vraag wordt niet weggefilterd'
)
from planning_result;
select is(
  (
    select (entry->>'totalOpenDemand')::integer
    from planning_result,
    jsonb_array_elements(payload->'demandByGender') entry
    where entry->>'gender' = 'male'
  ),
  1,
  'mannelijke open vraag is exact geaggregeerd'
);
select is(
  (
    select (entry->>'unpaidDemand')::integer
    from planning_result,
    jsonb_array_elements(payload->'demandByGender') entry
    where entry->>'gender' = 'female'
  ),
  2,
  'onbetaalde vrouwelijke vraag is alleen als telling zichtbaar'
);
select is(
  (
    select (entry->>'conflict')::integer
    from planning_result,
    jsonb_array_elements(payload->'unresolvedSizeDemand') entry
    where entry->>'gender' = 'unknown'
  ),
  3,
  'Anders/conflict telt zonder fictieve maatvariant'
);
select is(
  (
    select (entry->>'unconfirmed')::integer
    from planning_result,
    jsonb_array_elements(payload->'unresolvedSizeDemand') entry
    where entry->>'gender' = 'other'
  ),
  4,
  'geïmporteerde onbevestigde maat telt afzonderlijk'
);
select ok(
  (select payload::text from planning_result)
    not like '%GEHEIME-RUWE-MAAT%'
  and (select payload::text from planning_result)
    not like '%supplier-male@example.invalid%'
  and (select payload::text from planning_result)
    not like '%PRIVE-%',
  'ruwe maat, e-mail en team lekken niet in de planningresponse'
);
select is(
  (
    with recursive nodes(value) as (
      select payload from planning_result
      union all
      select child.value
      from nodes parent
      cross join lateral jsonb_path_query(parent.value, '$.*') child(value)
    ),
    object_keys as (
      select key
      from nodes
      cross join lateral jsonb_object_keys(
        case
          when jsonb_typeof(value) = 'object' then value
          else '{}'::jsonb
        end
      ) key
    )
    select count(*)::integer
    from object_keys
    where lower(key) in (
      'member',
      'memberid',
      'membername',
      'firstname',
      'lastname',
      'email',
      'dateofbirth',
      'dob',
      'team',
      'relationnumber',
      'orderid',
      'paymentid',
      'amountcents',
      'paidat',
      'fifoat'
    )
  ),
  0,
  'planningcontract bevat recursief geen individuele PII-sleutels'
);
select ok(
  exists(
    select 1
    from private.supplier_planner_events event
    where event.event_type = 'planning_viewed'
      and event.season_id = 'fa100000-0000-4000-8000-000000000001'
      and event.credential_version = 1
      and event.row_count > 0
      and event.response_hash ~ '^[0-9a-f]{64}$'
      and event.correlation_id =
        'fa900000-0000-4000-8000-000000000001'
  ),
  'planningread bewaart alleen veilige immutable bewijseigenschappen'
);

select lives_ok(
  $$select app.create_supplier_planner_session_v1(
    repeat('d', 64),
    repeat('e', 64),
    repeat('f', 64)
  )$$,
  'onbekende sleutel geeft een neutrale mislukte login'
);
select is(
  (
    select count(*)::integer
    from private.supplier_planner_events
    where event_type = 'login_failed'
  ),
  1,
  'geaccepteerde mislukte loginpoging wordt zonder IP of token geaudit'
);

select lives_ok(
  $$select app.manage_supplier_planner_v1(
    'rotate',
    'fa000000-0000-4000-8000-000000000001',
    (select token_hash from admin_session),
    'fa800000-0000-4000-8000-000000000002',
    (select (payload #>> '{principal,id}')::uuid from principal_result),
    null,
    repeat('9', 64),
    'Periodieke sleutelrotatie',
    null
  )$$,
  'beheerder roteert een suppliercredential atomair'
);
select ok(
  app.get_supplier_planner_context_v1(repeat('b', 64)) is null,
  'rotatie trekt de bestaande suppliersessie direct in'
);
select is(
  (
    app.get_operational_health_v10(
      repeat('1', 64),
      1,
      null,
      null
    ) #>> '{supplierPlanning,unauthorizedActiveSessions}'
  )::integer,
  0,
  'rotatie laat geen actieve zombiesessie achter'
);

select * from finish();
rollback;
