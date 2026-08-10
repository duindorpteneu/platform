begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

select has_table(
  'app',
  'inventory_delivery_notification_proposals',
  'leveringnotificatievoorstellen hebben een duurzame ledger'
);
select has_table(
  'app',
  'inventory_delivery_notification_items',
  'iedere leveringallocatie heeft een afzonderlijke voorstelregel'
);
select has_function(
  'app',
  'get_inventory_delivery_notification_proposal_v1',
  array['uuid'],
  'AAL2-operations kan een actueel voorstel previewen'
);
select has_function(
  'app',
  'confirm_inventory_delivery_notification_proposal_v1',
  array['uuid', 'text', 'uuid[]', 'uuid', 'uuid'],
  'expliciete selectiebevestiging heeft een eigen transactionele RPC'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'app.inventory_delivery_notification_proposals',
    'INSERT'
  )
  and not has_table_privilege(
    'authenticated',
    'app.inventory_delivery_notification_proposals',
    'UPDATE'
  )
  and not has_table_privilege(
    'authenticated',
    'app.inventory_delivery_notification_proposals',
    'DELETE'
  )
  and not has_table_privilege(
    'authenticated',
    'app.inventory_delivery_notification_items',
    'INSERT'
  )
  and not has_table_privilege(
    'authenticated',
    'app.inventory_delivery_notification_items',
    'UPDATE'
  )
  and not has_table_privilege(
    'authenticated',
    'app.inventory_delivery_notification_items',
    'DELETE'
  ),
  'browserrollen kunnen voorstel- en itemledgers niet rechtstreeks muteren'
);

select ok(
  not exists(
    select 1
    from information_schema.columns column_info
    where column_info.table_schema = 'app'
      and column_info.table_name in (
        'inventory_delivery_notification_proposals',
        'inventory_delivery_notification_items'
      )
      and lower(regexp_replace(
        column_info.column_name,
        '[^a-zA-Z0-9]',
        '',
        'g'
      )) ~ (
        'email|name|dateofbirth|dob|relationnumber|token|secret|'
        || 'otp|qr|rawvalue|membernote|password'
      )
  ),
  'de duurzame voorstelledgers bevatten geen PII- of geheimkolommen'
);

select ok(
  exists(
    select 1
    from pg_trigger trigger_row
    join pg_class relation on relation.oid = trigger_row.tgrelid
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'app'
      and relation.relname = 'inventory_delivery_drafts'
      and trigger_row.tgname =
        'inventory_delivery_drafts_notification_proposal'
      and not trigger_row.tgisinternal
  ),
  'posten maakt atomair een PII-vrij voorstel'
);

select ok(
  exists(
    select 1
    from pg_trigger trigger_row
    join pg_class relation on relation.oid = trigger_row.tgrelid
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'app'
      and relation.relname = 'inventory_allocation_events'
      and trigger_row.tgname =
        'inventory_allocation_events_delivery_notification_item'
      and not trigger_row.tgisinternal
  ),
  'delivery-allocatie-events worden atomair aan voorstelregels gebonden'
);

select ok(
  pg_get_functiondef(
    'private.produce_pickup_ready_v2()'::regprocedure
  ) like '%new.source_type = ''inventory_delivery''%',
  'alleen delivery-sourced allocaties slaan de automatische mailproducer over'
);

insert into app.staff_profiles(auth_user_id, display_name, role) values
  (
    'd4400000-0000-4000-8000-000000000001',
    'Notificatiecommissie',
    'kledingcommissie'
  ),
  (
    'd4400000-0000-4000-8000-000000000002',
    'Notificatie-uitgifte',
    'uitgifte'
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"d4400000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_inventory_delivery_notification_proposal_v1(
    'd4400000-0000-4000-8000-000000000010'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan zonder actuele AAL2 geen voorstel previewen'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"d4400000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_inventory_delivery_notification_proposal_v1(
    'd4400000-0000-4000-8000-000000000010'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte krijgt ook onder AAL2 geen leveringnotificatievoorstel'
);
reset role;

select * from finish();
rollback;
