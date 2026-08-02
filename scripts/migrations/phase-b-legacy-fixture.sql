\set ON_ERROR_STOP on

begin;

insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
) values (
  'eb100000-0000-4000-8000-000000000001',
  'Legacy upgrade 2041/2042',
  '2041-07-01',
  '2042-06-30',
  9999,
  'open',
  timezone('utc', now())
);

insert into app.app_settings(id, club_name, active_season_id)
values(
  true,
  'Duindorp SV',
  'eb100000-0000-4000-8000-000000000001'
)
on conflict(id) do update
set active_season_id = excluded.active_season_id;

insert into app.articles(id, name, code, icon_type, sort_order) values
  (
    'eb200000-0000-4000-8000-000000000001',
    'Legacy Keeper-broek',
    'LEG-KEEP',
    'circle-dot',
    10
  ),
  (
    'eb200000-0000-4000-8000-000000000002',
    'Legacy Speler-shirt',
    'LEG-SPEL',
    'shirt',
    20
  );

insert into app.article_variants(id, article_id, size, sku, sort_order) values
  (
    'eb300000-0000-4000-8000-000000000001',
    'eb200000-0000-4000-8000-000000000001',
    '152',
    'LEG-KEEP-152',
    10
  ),
  (
    'eb300000-0000-4000-8000-000000000002',
    'eb200000-0000-4000-8000-000000000002',
    '164',
    'LEG-SPEL-164',
    20
  );

insert into app.article_seasons(article_id, season_id) values
  ('eb200000-0000-4000-8000-000000000001', 'eb100000-0000-4000-8000-000000000001'),
  ('eb200000-0000-4000-8000-000000000002', 'eb100000-0000-4000-8000-000000000001');

insert into app.members(
  id, relation_number, first_name, last_name, email, team, active_for_season
) values
  (
    'eb400000-0000-4000-8000-000000000001',
    'UPGRADE-001',
    'Jamie',
    'Fixture',
    'upgrade-family@example.invalid',
    'Keeper-team zonder classificatie',
    true
  ),
  (
    'eb400000-0000-4000-8000-000000000002',
    'UPGRADE-002',
    'Taylor',
    'Fixture',
    'upgrade-family@example.invalid',
    'Speler-team zonder classificatie',
    true
  );

insert into app.member_orders(
  id, member_id, season_id, amount_due_cents, order_status
) values
  (
    'eb500000-0000-4000-8000-000000000001',
    'eb400000-0000-4000-8000-000000000001',
    'eb100000-0000-4000-8000-000000000001',
    12500,
    'Gedeeltelijk afgehaald'
  ),
  (
    'eb500000-0000-4000-8000-000000000002',
    'eb400000-0000-4000-8000-000000000002',
    'eb100000-0000-4000-8000-000000000001',
    13500,
    'Gedeeltelijk af te halen'
  );

insert into app.order_lines(
  id, order_id, article_variant_id, quantity, status
) values
  (
    'eb600000-0000-4000-8000-000000000001',
    'eb500000-0000-4000-8000-000000000001',
    'eb300000-0000-4000-8000-000000000001',
    1,
    'picked_up'
  ),
  (
    'eb600000-0000-4000-8000-000000000002',
    'eb500000-0000-4000-8000-000000000002',
    'eb300000-0000-4000-8000-000000000002',
    1,
    'ready_for_pickup'
  ),
  (
    'eb600000-0000-4000-8000-000000000003',
    'eb500000-0000-4000-8000-000000000002',
    'eb300000-0000-4000-8000-000000000001',
    1,
    'backorder'
  );

insert into app.payments(
  id, order_id, method, status, amount_cents, currency,
  provider_payment_id, idempotency_key, paid_at
) values
  (
    'eb700000-0000-4000-8000-000000000001',
    'eb500000-0000-4000-8000-000000000001',
    'mollie',
    'paid',
    12500,
    'EUR',
    'tr_upgrade_paid',
    'phase-b-upgrade-paid',
    timezone('utc', now()) - interval '2 days'
  ),
  (
    'eb700000-0000-4000-8000-000000000002',
    'eb500000-0000-4000-8000-000000000002',
    'mollie',
    'pending',
    13500,
    'EUR',
    'tr_upgrade_pending',
    'phase-b-upgrade-pending',
    null
  );

insert into app.delivery_receipts(
  id, received_on, supplier, packing_slip_reference, actor_user_id
) values (
  'eb800000-0000-4000-8000-000000000001',
  current_date - 7,
  'Upgrade Fixture Supplier',
  'UPGRADE-PS-001',
  'eb000000-0000-4000-8000-000000000001'
);

insert into app.delivery_receipt_lines(
  id, receipt_id, article_variant_id, received_quantity
) values
  (
    'eb810000-0000-4000-8000-000000000001',
    'eb800000-0000-4000-8000-000000000001',
    'eb300000-0000-4000-8000-000000000001',
    4
  ),
  (
    'eb810000-0000-4000-8000-000000000002',
    'eb800000-0000-4000-8000-000000000001',
    'eb300000-0000-4000-8000-000000000002',
    3
  );

insert into app.inventory_reservations(
  id, receipt_line_id, order_line_id, quantity, status, actor_user_id
) values
  (
    'eb820000-0000-4000-8000-000000000001',
    'eb810000-0000-4000-8000-000000000001',
    'eb600000-0000-4000-8000-000000000001',
    1,
    'fulfilled',
    'eb000000-0000-4000-8000-000000000001'
  ),
  (
    'eb820000-0000-4000-8000-000000000002',
    'eb810000-0000-4000-8000-000000000002',
    'eb600000-0000-4000-8000-000000000002',
    1,
    'reserved',
    'eb000000-0000-4000-8000-000000000001'
  ),
  (
    'eb820000-0000-4000-8000-000000000003',
    'eb810000-0000-4000-8000-000000000001',
    'eb600000-0000-4000-8000-000000000003',
    1,
    'released',
    'eb000000-0000-4000-8000-000000000001'
  );

insert into app.fulfilments(
  id, order_id, actor_user_id, location
) values (
  'eb830000-0000-4000-8000-000000000001',
  'eb500000-0000-4000-8000-000000000001',
  'eb000000-0000-4000-8000-000000000002',
  'Upgrade fixture balie'
);

insert into app.fulfilment_lines(
  id, fulfilment_id, order_line_id, reservation_id, quantity
) values (
  'eb840000-0000-4000-8000-000000000001',
  'eb830000-0000-4000-8000-000000000001',
  'eb600000-0000-4000-8000-000000000001',
  'eb820000-0000-4000-8000-000000000001',
  1
);

insert into private.qr_tokens(
  id, order_id, token_hash, version, active
) values (
  'eb850000-0000-4000-8000-000000000001',
  'eb500000-0000-4000-8000-000000000001',
  repeat('e', 64),
  1,
  true
);

insert into private.parent_accounts(id, email_normalized)
values(
  'eb860000-0000-4000-8000-000000000001',
  'upgrade-family@example.invalid'
);

insert into private.parent_member_links(
  id, parent_account_id, member_id
) values (
  'eb870000-0000-4000-8000-000000000001',
  'eb860000-0000-4000-8000-000000000001',
  'eb400000-0000-4000-8000-000000000001'
);

commit;
