begin;

create extension if not exists pgtap with schema extensions;
select plan(27);

insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('70000000-0000-4000-8000-000000000001', 'Leden commissie', 'kledingcommissie'),
  ('70000000-0000-4000-8000-000000000002', 'Leden uitgifte', 'uitgifte');

insert into app.seasons (id, name, default_amount_cents, status)
values ('71000000-0000-4000-8000-000000000001', 'Ledenseizoen', 12500, 'open');
update app.app_settings set active_season_id = '71000000-0000-4000-8000-000000000001' where id = true;

insert into app.articles (id, name, code, sort_order)
values
  ('72000000-0000-4000-8000-000000000001', 'Ledenshirt', 'LEDEN-SHIRT', 201),
  ('72000000-0000-4000-8000-000000000002', 'Ledenbroekje', 'LEDEN-BROEK', 202);
insert into app.article_variants (id, article_id, size, sku)
values
  ('73000000-0000-4000-8000-000000000001', '72000000-0000-4000-8000-000000000001', 'M', 'LEDEN-M'),
  ('73000000-0000-4000-8000-000000000002', '72000000-0000-4000-8000-000000000002', 'L', 'LEDEN-L');

insert into app.members (id, relation_number, first_name, last_name, email, team, active_for_season)
values
  ('74000000-0000-4000-8000-000000000001', 'LED-001', 'Sophie', 'Tester', 'sophie-leden@example.invalid', 'JO11-1', true),
  ('74000000-0000-4000-8000-000000000002', 'LED-002', 'Yassin', 'Tester', 'yassin-leden@example.invalid', 'JO13-2', true),
  ('74000000-0000-4000-8000-000000000003', 'LED-003', 'Noa', 'Zonderorder', 'noa-leden@example.invalid', 'JO13-2', false);

insert into app.member_orders (id, member_id, season_id, amount_due_cents, order_status)
values
  ('75000000-0000-4000-8000-000000000001', '74000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000001', 12500, 'Gedeeltelijk af te halen'),
  ('75000000-0000-4000-8000-000000000002', '74000000-0000-4000-8000-000000000002', '71000000-0000-4000-8000-000000000001', 12500, 'Nalevering');
insert into app.order_lines (id, order_id, article_variant_id, quantity, status)
values
  ('76000000-0000-4000-8000-000000000001', '75000000-0000-4000-8000-000000000001', '73000000-0000-4000-8000-000000000001', 1, 'ready_for_pickup'),
  ('76000000-0000-4000-8000-000000000002', '75000000-0000-4000-8000-000000000001', '73000000-0000-4000-8000-000000000002', 1, 'backorder'),
  ('76000000-0000-4000-8000-000000000003', '75000000-0000-4000-8000-000000000002', '73000000-0000-4000-8000-000000000002', 1, 'backorder');
insert into app.payments (order_id, method, status, amount_cents, idempotency_key, paid_at)
values ('75000000-0000-4000-8000-000000000001', 'card', 'paid', 12500, 'member-overview-paid', now());

insert into private.parent_accounts (id, email_normalized)
values ('77000000-0000-4000-8000-000000000001', 'ouder-leden@example.invalid');
insert into private.parent_member_links (parent_account_id, member_id)
values ('77000000-0000-4000-8000-000000000001', '74000000-0000-4000-8000-000000000001');
insert into private.qr_tokens (order_id, token_hash, version, created_by)
values ('75000000-0000-4000-8000-000000000001', repeat('a', 64), 1, '70000000-0000-4000-8000-000000000001');
insert into app.audit_logs (actor_user_id, action, entity_type, entity_id)
values
  ('70000000-0000-4000-8000-000000000001', 'payment.manual.recorded', 'member_order', '75000000-0000-4000-8000-000000000001'),
  ('70000000-0000-4000-8000-000000000002', 'qr.lookup', 'member_order', '75000000-0000-4000-8000-000000000001');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"70000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok(
  $$select app.get_member_list()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan de ledenlijst niet openen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"70000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select app.get_member_list()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan leden niet enumereren'
);
select throws_ok(
  $$select app.get_member_detail('74000000-0000-4000-8000-000000000001')$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan het backofficedetail niet openen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"70000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select is((app.get_member_list() #>> '{totalCount}')::integer, 3, 'totaal bevat alle leden');
select is((app.get_member_list() #>> '{activeCount}')::integer, 2, 'actieftelling is exact');
select is((app.get_member_list() #>> '{filteredCount}')::integer, 3, 'ongefilterde telling is exact');
select is(jsonb_array_length(app.get_member_list()->'members'), 3, 'ongefilterde pagina bevat drie leden');
select ok(position('email' in (app.get_member_list()->'members')::text) = 0, 'ledenlijst bevat geen e-mailadres');
select is((app.get_member_list(p_search => 'Sophie') #>> '{filteredCount}')::integer, 1, 'zoeken op naam werkt');
select is((app.get_member_list(p_team => 'JO13-2') #>> '{filteredCount}')::integer, 2, 'teamfilter werkt');
select is((app.get_member_list(p_payment_filter => 'paid') #>> '{filteredCount}')::integer, 1, 'betaaldfilter werkt');
select is((app.get_member_list(p_payment_filter => 'unpaid') #>> '{filteredCount}')::integer, 1, 'onbetaaldfilter werkt');
select is((app.get_member_list(p_payment_filter => 'no_order') #>> '{filteredCount}')::integer, 1, 'zonder-bestellingfilter werkt');
select is((app.get_member_list(p_order_status => 'Nalevering') #>> '{filteredCount}')::integer, 1, 'bestelstatusfilter werkt');
select is((app.get_member_list(p_article_id => '72000000-0000-4000-8000-000000000001') #>> '{filteredCount}')::integer, 1, 'artikelfilter werkt');
select is((app.get_member_list(p_size => 'L') #>> '{filteredCount}')::integer, 2, 'maatfilter werkt');
select is((app.get_member_list(p_line_status => 'ready_for_pickup') #>> '{filteredCount}')::integer, 1, 'uitgiftestatusfilter werkt');
select is(jsonb_array_length(app.get_member_list(p_limit => 1, p_offset => 1)->'members'), 1, 'paginering begrenst resultaten');
select throws_ok(
  $$select app.get_member_list(p_payment_filter => 'arbitrary')$$,
  '22023',
  'INVALID_PAYMENT_FILTER',
  'willekeurig betaalfilter wordt geweigerd'
);

select is(app.get_member_detail('74000000-0000-4000-8000-000000000001') #>> '{email}', 'sophie-leden@example.invalid', 'detail bevat operationeel e-mailadres');
select is(jsonb_array_length(app.get_member_detail('74000000-0000-4000-8000-000000000001')->'parentLinks'), 1, 'detail bevat expliciete ouderkoppeling');
select is((app.get_member_detail('74000000-0000-4000-8000-000000000001') #>> '{order,amountDueCents}')::integer, 12500, 'detail bevat exact orderbedrag');
select is(app.get_member_detail('74000000-0000-4000-8000-000000000001') #>> '{order,qrStatus}', 'Actief', 'detail bevat alleen QR-status');
select is(jsonb_array_length(app.get_member_detail('74000000-0000-4000-8000-000000000001') #> '{order,lines}'), 2, 'detail bevat artikelregels');
select is(jsonb_array_length(app.get_member_detail('74000000-0000-4000-8000-000000000001')->'activities'), 1, 'QR-lookups zijn uit detailhistorie gefilterd');
select is(app.get_member_detail('74000000-0000-4000-8000-000000000001') #>> '{activeSeason,name}', 'Ledenseizoen', 'detail gebruikt actief seizoen');
select throws_ok(
  $$select app.get_member_detail('74000000-0000-4000-8000-000000000099')$$,
  'P0002',
  'MEMBER_NOT_FOUND',
  'onbekend lid geeft geen leeg detail'
);

select * from finish();
rollback;
