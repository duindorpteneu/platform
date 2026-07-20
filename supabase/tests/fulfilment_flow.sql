begin;

create extension if not exists pgtap with schema extensions;
select plan(12);

insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('30000000-0000-4000-8000-000000000001', 'Voorraadtest', 'kledingcommissie'),
  ('30000000-0000-4000-8000-000000000002', 'Uitgiftetest', 'uitgifte');

insert into app.seasons (id, name, default_amount_cents, status)
values ('31000000-0000-4000-8000-000000000001', 'DB-testseizoen', 12500, 'open');
update app.app_settings set active_season_id = '31000000-0000-4000-8000-000000000001' where id = true;

insert into app.articles (id, name, code, sort_order)
values
  ('32000000-0000-4000-8000-000000000001', 'DB-testshirt', 'DB-SHIRT', 99),
  ('32000000-0000-4000-8000-000000000002', 'DB-testbroek', 'DB-BROEK', 100);

insert into app.article_variants (id, article_id, size, sku)
values
  ('33000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000001', 'TEST', 'DB-TEST-1'),
  ('33000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000002', 'TEST', 'DB-TEST-2');

insert into app.members (id, relation_number, first_name, last_name, email, team)
values
  ('34000000-0000-4000-8000-000000000001', 'DB-001', 'Eerste', 'Testlid', 'eerste@example.invalid', 'Testteam'),
  ('34000000-0000-4000-8000-000000000002', 'DB-002', 'Tweede', 'Testlid', 'tweede@example.invalid', 'Testteam');

insert into app.member_orders (id, member_id, season_id, amount_due_cents)
values
  ('35000000-0000-4000-8000-000000000001', '34000000-0000-4000-8000-000000000001', '31000000-0000-4000-8000-000000000001', 12500),
  ('35000000-0000-4000-8000-000000000002', '34000000-0000-4000-8000-000000000002', '31000000-0000-4000-8000-000000000001', 12500);

insert into app.order_lines (id, order_id, article_variant_id)
values
  ('36000000-0000-4000-8000-000000000001', '35000000-0000-4000-8000-000000000001', '33000000-0000-4000-8000-000000000001'),
  ('36000000-0000-4000-8000-000000000002', '35000000-0000-4000-8000-000000000001', '33000000-0000-4000-8000-000000000002'),
  ('36000000-0000-4000-8000-000000000003', '35000000-0000-4000-8000-000000000002', '33000000-0000-4000-8000-000000000001');

insert into app.payments (order_id, method, status, amount_cents, idempotency_key, paid_at)
values ('35000000-0000-4000-8000-000000000001', 'card', 'paid', 12500, 'db-test-payment-0001', timezone('utc', now()));

insert into private.qr_tokens (order_id, token_hash, version)
values ('35000000-0000-4000-8000-000000000001', repeat('a', 64), 1);

select set_config('request.jwt.claims', '{"sub":"30000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;

select lives_ok(
  $$select app.register_delivery_receipt(current_date, 'DB-testleverancier', 'DB-PAKBON', '[{"variant_id":"33000000-0000-4000-8000-000000000001","quantity":1},{"variant_id":"33000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb)$$,
  'kledingcommissie kan twee stuks ontvangen'
);

select lives_ok(
  $$select app.reserve_order_lines((select drl.id from app.delivery_receipt_lines drl join app.delivery_receipts dr on dr.id = drl.receipt_id where dr.supplier = 'DB-testleverancier' and drl.article_variant_id = '33000000-0000-4000-8000-000000000001'), array['36000000-0000-4000-8000-000000000001'::uuid])$$,
  'eerste artikelregel wordt gereserveerd'
);
select lives_ok(
  $$select app.reserve_order_lines((select drl.id from app.delivery_receipt_lines drl join app.delivery_receipts dr on dr.id = drl.receipt_id where dr.supplier = 'DB-testleverancier' and drl.article_variant_id = '33000000-0000-4000-8000-000000000002'), array['36000000-0000-4000-8000-000000000002'::uuid])$$,
  'tweede artikelregel wordt apart gereserveerd'
);

select throws_ok(
  $$select app.reserve_order_lines((select drl.id from app.delivery_receipt_lines drl join app.delivery_receipts dr on dr.id = drl.receipt_id where dr.supplier = 'DB-testleverancier' and drl.article_variant_id = '33000000-0000-4000-8000-000000000001'), array['36000000-0000-4000-8000-000000000003'::uuid])$$,
  '23514',
  'INSUFFICIENT_STOCK',
  'reserveren boven beschikbare voorraad wordt geblokkeerd'
);

reset role;
select is((select status::text from app.order_lines where id = '36000000-0000-4000-8000-000000000001'), 'ready_for_pickup', 'eerste regel staat af te halen');
select is((select status::text from app.order_lines where id = '36000000-0000-4000-8000-000000000002'), 'ready_for_pickup', 'tweede regel staat af te halen');
select is((select status::text from app.order_lines where id = '36000000-0000-4000-8000-000000000003'), 'backorder', 'niet gereserveerde regel blijft nalevering');

select set_config('request.jwt.claims', '{"sub":"30000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select is(app.lookup_fulfilment(repeat('a', 64))->>'status', 'found', 'de actieve QR resolveert voor uitgifte');
select lives_ok(
  $$select app.commit_fulfilment('35000000-0000-4000-8000-000000000001', array['36000000-0000-4000-8000-000000000001'::uuid], 'DB-testbalie', repeat('a', 64))$$,
  'eerste deeluitgifte slaagt'
);
select throws_ok(
  $$select app.commit_fulfilment('35000000-0000-4000-8000-000000000001', array['36000000-0000-4000-8000-000000000001'::uuid], 'DB-testbalie', repeat('a', 64))$$,
  '23514',
  'ORDER_LINE_NOT_READY',
  'dezelfde regel kan niet dubbel worden uitgegeven'
);
select lives_ok(
  $$select app.commit_fulfilment('35000000-0000-4000-8000-000000000001', array['36000000-0000-4000-8000-000000000002'::uuid], 'DB-testbalie', repeat('a', 64))$$,
  'dezelfde QR rondt een later uitgiftemoment af'
);

reset role;
select is((select order_status from app.member_orders where id = '35000000-0000-4000-8000-000000000001'), 'Afgerond', 'orderstatus wordt server-side afgerond');

select * from finish();
rollback;
