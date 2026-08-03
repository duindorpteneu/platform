begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('f1000000-0000-4000-8000-000000000001', 'Voorraadbeheer', 'beheerder'),
  ('f1000000-0000-4000-8000-000000000002', 'Voorraadcommissie', 'kledingcommissie'),
  ('f1000000-0000-4000-8000-000000000003', 'Voorraaduitgifte', 'uitgifte');

insert into app.seasons(id, name, default_amount_cents, status) values
  ('f1100000-0000-4000-8000-000000000001', 'Journaal 2026-2027', 12500, 'open');
update app.app_settings
set active_season_id = 'f1100000-0000-4000-8000-000000000001'
where id = true;

insert into app.articles(id, name, code, sort_order, active) values
  ('f1200000-0000-4000-8000-000000000001', 'Journaalshirt', 'JOUR-SHIRT', 800, true);
insert into app.article_seasons(article_id, season_id) values
  (
    'f1200000-0000-4000-8000-000000000001',
    'f1100000-0000-4000-8000-000000000001'
  );
insert into app.article_variants(
  id, article_id, size, sku, sort_order, active
) values
  (
    'f1300000-0000-4000-8000-000000000001',
    'f1200000-0000-4000-8000-000000000001',
    'M',
    'JOUR-M',
    1,
    true
  ),
  (
    'f1300000-0000-4000-8000-000000000002',
    'f1200000-0000-4000-8000-000000000001',
    'L',
    'JOUR-L',
    2,
    true
  );

insert into app.members(
  id, relation_number, first_name, last_name, email, team
) values
  (
    'f1400000-0000-4000-8000-000000000001',
    'JOUR-001',
    'Eerste',
    'FIFO',
    'jour-eerste@example.invalid',
    'JO11-1'
  ),
  (
    'f1400000-0000-4000-8000-000000000002',
    'JOUR-002',
    'Tweede',
    'FIFO',
    'jour-tweede@example.invalid',
    'JO11-1'
  ),
  (
    'f1400000-0000-4000-8000-000000000003',
    'JOUR-003',
    'Onbetaald',
    'FIFO',
    'jour-onbetaald@example.invalid',
    'JO11-1'
  ),
  (
    'f1400000-0000-4000-8000-000000000004',
    'JOUR-004',
    'Onbevestigd',
    'FIFO',
    'jour-onbevestigd@example.invalid',
    'JO11-1'
  );

insert into app.member_orders(
  id, member_id, season_id, amount_due_cents
) values
  (
    'f1500000-0000-4000-8000-000000000001',
    'f1400000-0000-4000-8000-000000000001',
    'f1100000-0000-4000-8000-000000000001',
    12500
  ),
  (
    'f1500000-0000-4000-8000-000000000002',
    'f1400000-0000-4000-8000-000000000002',
    'f1100000-0000-4000-8000-000000000001',
    12500
  ),
  (
    'f1500000-0000-4000-8000-000000000003',
    'f1400000-0000-4000-8000-000000000003',
    'f1100000-0000-4000-8000-000000000001',
    12500
  ),
  (
    'f1500000-0000-4000-8000-000000000004',
    'f1400000-0000-4000-8000-000000000004',
    'f1100000-0000-4000-8000-000000000001',
    12500
  );
insert into app.order_lines(id, order_id, article_variant_id) values
  (
    'f1600000-0000-4000-8000-000000000001',
    'f1500000-0000-4000-8000-000000000001',
    'f1300000-0000-4000-8000-000000000001'
  ),
  (
    'f1600000-0000-4000-8000-000000000002',
    'f1500000-0000-4000-8000-000000000002',
    'f1300000-0000-4000-8000-000000000001'
  ),
  (
    'f1600000-0000-4000-8000-000000000003',
    'f1500000-0000-4000-8000-000000000003',
    'f1300000-0000-4000-8000-000000000001'
  ),
  (
    'f1600000-0000-4000-8000-000000000004',
    'f1500000-0000-4000-8000-000000000004',
    'f1300000-0000-4000-8000-000000000001'
  );

select set_config('app.package_size_internal', 'on', true);
insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  member_season_id,
  selection_status,
  selection_source,
  confirmed_at
)
select
  member.id,
  member_season.season_id,
  'f1200000-0000-4000-8000-000000000001',
  'f1300000-0000-4000-8000-000000000001',
  member_season.id,
  case
    when member.id = 'f1400000-0000-4000-8000-000000000004'
    then 'imported_unconfirmed'::app.size_selection_status
    else 'confirmed'::app.size_selection_status
  end,
  case
    when member.id = 'f1400000-0000-4000-8000-000000000004'
    then 'import'::app.size_selection_source
    else 'staff'::app.size_selection_source
  end,
  case
    when member.id = 'f1400000-0000-4000-8000-000000000004'
    then null
    else timezone('utc', now()) - interval '2 days'
  end
from app.members member
join app.member_seasons member_season
  on member_season.member_id = member.id
  and member_season.season_id = 'f1100000-0000-4000-8000-000000000001'
where member.id::text like 'f1400000-%'
on conflict (member_id, season_id, article_id) do update
set article_variant_id = excluded.article_variant_id,
    member_season_id = excluded.member_season_id,
    selection_status = excluded.selection_status,
    selection_source = excluded.selection_source,
    raw_value = null,
    member_note = null,
    confirmed_at = excluded.confirmed_at,
    confirmed_by = null,
    updated_at = timezone('utc', now());
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
    'f1700000-0000-4000-8000-000000000001',
    'f1500000-0000-4000-8000-000000000001',
    'cash',
    'paid',
    12500,
    'inventory-fifo-paid-0001',
    timezone('utc', now()) - interval '3 days'
  ),
  (
    'f1700000-0000-4000-8000-000000000002',
    'f1500000-0000-4000-8000-000000000002',
    'cash',
    'paid',
    12500,
    'inventory-fifo-paid-0002',
    timezone('utc', now()) - interval '1 day'
  ),
  (
    'f1700000-0000-4000-8000-000000000004',
    'f1500000-0000-4000-8000-000000000004',
    'cash',
    'paid',
    12500,
    'inventory-fifo-paid-0004',
    timezone('utc', now()) - interval '4 days'
  );

select ok(
  not has_table_privilege('authenticated', 'app.inventory_movements', 'INSERT')
  and not has_table_privilege('authenticated', 'app.inventory_movements', 'UPDATE')
  and not has_table_privilege('authenticated', 'app.inventory_movements', 'DELETE')
  and not has_table_privilege('service_role', 'app.inventory_movements', 'INSERT')
  and not has_table_privilege('service_role', 'app.inventory_movements', 'UPDATE')
  and not has_table_privilege('service_role', 'app.inventory_movements', 'DELETE'),
  'authenticated en service role kunnen het journaal niet rechtstreeks muteren'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"f1000000-0000-4000-8000-000000000002","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.create_inventory_delivery_draft(
    'f1100000-0000-4000-8000-000000000001',
    current_date,
    'AAL1 geweigerd',
    null,
    array['f1200000-0000-4000-8000-000000000001'::uuid],
    'f1800000-0000-4000-8000-000000000010'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie heeft actuele AAL2 nodig voor voorraadmutaties'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"f1000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_inventory_workspace(
    'f1100000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte krijgt geen voorraadoverzicht of planningsdata'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"f1000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_inventory_reconciliation_workspace()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie ziet de admin-only legacyreconciliatie niet'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"f1000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select app.create_inventory_delivery_draft(
    'f1100000-0000-4000-8000-000000000001',
    current_date,
    'Journaalleverancier',
    'JOUR-PAKBON-1',
    array['f1200000-0000-4000-8000-000000000001'::uuid],
    'f1800000-0000-4000-8000-000000000001'
  )$$,
  'kledingcommissie maakt een leveringconcept met alle actieve maten'
);

select is(
  (
    select count(*)
    from app.inventory_delivery_draft_lines line
    join app.inventory_delivery_drafts draft on draft.id = line.draft_id
    where draft.create_request_id = 'f1800000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'concept bevat automatisch beide actieve maatregels'
);

select throws_ok(
  $$select app.update_inventory_delivery_draft(
    (
      select id from app.inventory_delivery_drafts
      where create_request_id = 'f1800000-0000-4000-8000-000000000001'
    ),
    1,
    '[{"variantId":"f1300000-0000-4000-8000-000000000001","quantity":1,"confirmed":true}]',
    'f1800000-0000-4000-8000-000000000002'
  )$$,
  '23514',
  'INVENTORY_DELIVERY_FULL_MATRIX_REQUIRED',
  'een onvolledige maatmatrix kan niet worden opgeslagen'
);

select lives_ok(
  $$select app.update_inventory_delivery_draft(
    (
      select id from app.inventory_delivery_drafts
      where create_request_id = 'f1800000-0000-4000-8000-000000000001'
    ),
    1,
    '[
      {"variantId":"f1300000-0000-4000-8000-000000000001","quantity":1,"confirmed":true},
      {"variantId":"f1300000-0000-4000-8000-000000000002","quantity":0,"confirmed":true}
    ]',
    'f1800000-0000-4000-8000-000000000003'
  )$$,
  'iedere maat krijgt een bevestigd aantal of expliciete nul'
);

select throws_ok(
  $$select app.post_inventory_delivery_draft(
    (
      select id from app.inventory_delivery_drafts
      where create_request_id = 'f1800000-0000-4000-8000-000000000001'
    ),
    2,
    'f1800000-0000-4000-8000-000000000004'
  )$$,
  '55000',
  'INVENTORY_V2_NOT_ENABLED',
  'posten blijft vóór gecontroleerde cutover gesloten'
);

reset role;
update app.release_feature_flags
set enabled = true
where key = 'allocation_qr_v2';

select set_config(
  'request.jwt.claims',
  '{"sub":"f1000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select lives_ok(
  $$select app.post_inventory_delivery_draft(
    (
      select id from app.inventory_delivery_drafts
      where create_request_id = 'f1800000-0000-4000-8000-000000000001'
    ),
    2,
    'f1800000-0000-4000-8000-000000000004'
  )$$,
  'volledig bevestigd concept wordt atomair gepost'
);
select lives_ok(
  $$select app.post_inventory_delivery_draft(
    (
      select id from app.inventory_delivery_drafts
      where create_request_id = 'f1800000-0000-4000-8000-000000000001'
    ),
    2,
    'f1800000-0000-4000-8000-000000000004'
  )$$,
  'dezelfde post-request retourneert idempotent hetzelfde resultaat'
);
reset role;

select is(
  (
    select count(*) from app.delivery_receipt_lines line
    join app.delivery_receipts receipt on receipt.id = line.receipt_id
    where receipt.supplier = 'Journaalleverancier'
  ),
  1::bigint,
  'expliciete nul maakt geen fictieve fysieke ontvangstregel'
);
select is(
  (
    select coalesce(sum(on_hand_delta), 0)
    from app.inventory_movements
    where season_id = 'f1100000-0000-4000-8000-000000000001'
      and article_variant_id = 'f1300000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'journaal bevat exact één fysiek ontvangen stuk'
);
select is(
  (
    select order_line_id
    from app.inventory_allocations
    where status = 'reserved'
  ),
  'f1600000-0000-4000-8000-000000000001'::uuid,
  'FIFO reserveert de oudste gecombineerde betaling-en-maatprioriteit'
);
select is(
  (
    select count(*)
    from app.inventory_allocations
    where order_line_id in (
      'f1600000-0000-4000-8000-000000000003',
      'f1600000-0000-4000-8000-000000000004'
    )
  ),
  0::bigint,
  'onbetaalde en onbevestigde regels krijgen geen harde allocatie'
);
select is(
  (
    select count(*)
    from app.inventory_movements
    where movement_type = 'allocation_reserved'
  ),
  1::bigint,
  'allocatie schrijft exact één append-only reservebeweging'
);
select ok(
  exists(
    select 1 from app.action_items
    where type = 'paid_waiting_stock'
      and object_id = 'f1600000-0000-4000-8000-000000000002'
      and status = 'open'
  ),
  'betaalde tweede FIFO-regel krijgt één gededupliceerd actiepunt'
);

select throws_ok(
  $$update app.inventory_movements
    set reason_code = 'inventory.tampered'
    where movement_type = 'receipt'$$,
  '23514',
  'INVENTORY_EVENT_IMMUTABLE',
  'voorraadjournaal kan niet worden herschreven'
);
select throws_ok(
  $$insert into app.delivery_receipts(
      received_on, supplier, actor_user_id
    ) values (
      current_date,
      'Legacy bypass',
      'f1000000-0000-4000-8000-000000000002'
    )$$,
  '55000',
  'LEGACY_INVENTORY_MUTATION_DISABLED',
  'legacy ontvangst kan na cutover niet om het journaal heen'
);

update app.payments
set status = 'refunded',
    refunded_at = timezone('utc', now())
where id = 'f1700000-0000-4000-8000-000000000001';

select is(
  (
    select status::text
    from app.inventory_allocations
    where order_line_id = 'f1600000-0000-4000-8000-000000000001'
  ),
  'released',
  'refund geeft de nog niet uitgegeven allocatie transactioneel vrij'
);
select is(
  (
    select status::text
    from app.order_lines
    where id = 'f1600000-0000-4000-8000-000000000001'
  ),
  'backorder',
  'refund zet de vrijgegeven regel terug op nalevering'
);
select is(
  (
    select available
    from private.inventory_balance(
      'f1100000-0000-4000-8000-000000000001',
      'f1300000-0000-4000-8000-000000000001'
    )
  ),
  1::bigint,
  'vrijgave herstelt exact één vrij stuk'
);

set local role service_role;
select lives_ok(
  $$select app.process_inventory_allocation_queue(10)$$,
  'de serviceprocessor verwerkt de betaal-/maatqueue'
);
reset role;
select is(
  (
    select status::text
    from app.order_lines
    where id = 'f1600000-0000-4000-8000-000000000002'
  ),
  'ready_for_pickup',
  'na vrijgave krijgt de volgende FIFO-regel het beschikbare stuk'
);
select is(
  (
    select count(*)
    from app.inventory_allocations
    where order_line_id = 'f1600000-0000-4000-8000-000000000002'
      and status = 'reserved'
      and reconciliation_status = 'resolved'
  ),
  1::bigint,
  'nieuwe harde allocatie is betaald, maatgeldig en gereconcilieerd'
);
select is(
  (
    select count(*)
    from app.action_items
    where type = 'paid_waiting_stock'
      and object_id = 'f1600000-0000-4000-8000-000000000002'
      and status = 'open'
  ),
  0::bigint,
  'herstelde toestand lost het betaalde-wachtactiepunt automatisch op'
);

set local role anon;
select throws_ok(
  $$select * from app.inventory_movements$$,
  '42501',
  'permission denied for schema app',
  'anon kan het voorraadjournaal niet lezen'
);
reset role;

select * from finish();
rollback;
