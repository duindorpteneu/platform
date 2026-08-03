begin;

create extension if not exists pgtap with schema extensions;
select plan(17);

insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('50000000-0000-4000-8000-000000000001', 'Dashboard commissie', 'kledingcommissie'),
  ('50000000-0000-4000-8000-000000000002', 'Dashboard uitgifte', 'uitgifte');

insert into app.seasons (id, name, default_amount_cents, status)
values
  ('51000000-0000-4000-8000-000000000001', 'Dashboardseizoen', 12500, 'open'),
  ('51000000-0000-4000-8000-000000000002', 'Leeg dashboardseizoen', 12500, 'archived');

update app.app_settings set active_season_id = '51000000-0000-4000-8000-000000000001' where id = true;

insert into app.articles (id, name, code, sort_order)
values
  ('52000000-0000-4000-8000-000000000001', 'Dashboardshirt', 'DASH-SHIRT', 120),
  ('52000000-0000-4000-8000-000000000002', 'Dashboardbroek', 'DASH-BROEK', 121);

insert into app.article_variants (id, article_id, size, sku)
values
  ('53000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', 'DASH', 'DASH-001'),
  ('53000000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000002', 'DASH', 'DASH-002');

insert into app.members (id, relation_number, first_name, last_name, email, team, active_for_season)
values
  ('54000000-0000-4000-8000-000000000001', 'DASH-001', 'Eerste', 'Dashboardlid', 'eerste-dashboard@example.invalid', 'JO11-1', true),
  ('54000000-0000-4000-8000-000000000002', 'DASH-002', 'Tweede', 'Dashboardlid', 'tweede-dashboard@example.invalid', 'MO13-1', true),
  ('54000000-0000-4000-8000-000000000003', 'DASH-003', 'Inactief', 'Dashboardlid', 'inactief-dashboard@example.invalid', 'JO15-1', false);

insert into app.member_orders (id, member_id, season_id, amount_due_cents, order_status)
values
  ('55000000-0000-4000-8000-000000000001', '54000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001', 12500, 'Gedeeltelijk af te halen'),
  ('55000000-0000-4000-8000-000000000002', '54000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000001', 12500, 'Volledig af te halen');

insert into app.order_lines (id, order_id, article_variant_id, status)
values
  ('56000000-0000-4000-8000-000000000001', '55000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001', 'ready_for_pickup'),
  ('56000000-0000-4000-8000-000000000002', '55000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000002', 'backorder'),
  ('56000000-0000-4000-8000-000000000003', '55000000-0000-4000-8000-000000000002', '53000000-0000-4000-8000-000000000001', 'ready_for_pickup');

insert into app.payments (order_id, method, status, amount_cents, idempotency_key, paid_at)
values ('55000000-0000-4000-8000-000000000001', 'card', 'paid', 12500, 'dashboard-payment-0001', timezone('utc', now()));

insert into app.audit_logs (actor_user_id, action, entity_type, entity_id)
values
  ('50000000-0000-4000-8000-000000000001', 'members.import.commit', 'import_batch', null),
  ('50000000-0000-4000-8000-000000000001', 'stock.receipt.created', 'delivery_receipt', null),
  ('50000000-0000-4000-8000-000000000002', 'qr.lookup', 'member_order', '55000000-0000-4000-8000-000000000001');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"50000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok(
  $$select app.get_backoffice_dashboard()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan het backofficedashboard niet openen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"50000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select app.get_backoffice_dashboard()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan het backofficedashboard niet openen'
);
select is(app.get_staff_shell_context() #>> '{activeSeason,name}', 'Dashboardseizoen', 'uitgifte krijgt alleen de veilige shellcontext');

reset role;
select set_config('request.jwt.claims', '{"sub":"50000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select is((app.get_backoffice_dashboard() #>> '{metrics,totalMembers}')::integer, 2, 'alleen actieve leden worden geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,totalOrders}')::integer, 2, 'orders van het actieve seizoen worden geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,paidOrders}')::integer, 1, 'betaalde orders worden geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,unpaidOrders}')::integer, 1, 'onbetaalde orders worden geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,partiallyReadyOrders}')::integer, 1, 'gedeeltelijk af te halen wordt geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,fullyReadyOrders}')::integer, 1, 'volledig af te halen wordt geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,backorderOrders}')::integer, 1, 'orders met nalevering worden uniek geteld');
select is((app.get_backoffice_dashboard() #>> '{metrics,readyOrders}')::integer, 2, 'orders met gereedstaande regels worden uniek geteld');
select is(jsonb_array_length(app.get_backoffice_dashboard()->'recentMembers'), 2, 'recente leden bevat alleen actieve seizoensorders');
select ok(position('email' in (app.get_backoffice_dashboard()->'recentMembers')::text) = 0, 'dashboardresponse bevat geen e-mailadres');
select ok(
  not (
    app.get_backoffice_dashboard()->'activities'
      @> '[{"action":"qr.lookup"}]'::jsonb
  ),
  'dashboard toont nooit QR-lookups als activiteit'
);
select is(app.get_backoffice_dashboard() #>> '{activeSeason,name}', 'Dashboardseizoen', 'actief seizoen komt uit app-instellingen');

reset role;
update app.app_settings set active_season_id = '51000000-0000-4000-8000-000000000002' where id = true;
select set_config('request.jwt.claims', '{"sub":"50000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select is((app.get_backoffice_dashboard() #>> '{metrics,totalOrders}')::integer, 0, 'leeg seizoen heeft nul orders');
select is(jsonb_array_length(app.get_backoffice_dashboard()->'recentMembers'), 0, 'leeg seizoen heeft geen recente lidorders');

select * from finish();
rollback;
