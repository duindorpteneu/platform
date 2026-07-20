begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role, active) values
  ('cb000000-0000-4000-8000-000000000001', 'Bulk beheerder', 'beheerder', true),
  ('cb000000-0000-4000-8000-000000000002', 'Bulk commissie', 'kledingcommissie', true),
  ('cb000000-0000-4000-8000-000000000003', 'Bulk uitgifte', 'uitgifte', true);
insert into app.seasons(id, name, default_amount_cents, status, opened_at)
values('cb100000-0000-4000-8000-000000000001', '2040/2041 bulk', 8750, 'open', timezone('utc', now()));
update app.app_settings set active_season_id = 'cb100000-0000-4000-8000-000000000001' where id = true;

insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season) values
  ('cb200000-0000-4000-8000-000000000001', 'BULK-001', 'Actief', 'Nieuw', 'bulk-1@example.invalid', 'JO15-BULK', true),
  ('cb200000-0000-4000-8000-000000000002', 'BULK-002', 'Actief', 'Open', 'bulk-2@example.invalid', 'JO15-BULK', true),
  ('cb200000-0000-4000-8000-000000000003', 'BULK-003', 'Actief', 'Betaald', 'bulk-3@example.invalid', 'JO15-BULK', true),
  ('cb200000-0000-4000-8000-000000000004', 'BULK-004', 'Inactief', 'Lid', 'bulk-4@example.invalid', 'JO15-BULK', false);
insert into app.articles(id, name, code, icon_type, active, sort_order) values
  ('cb300000-0000-4000-8000-000000000001', 'Bulkshirt', 'BULK-SHIRT', 'shirt', true, 401),
  ('cb300000-0000-4000-8000-000000000002', 'Bulkbroek', 'BULK-BROEK', 'package', true, 402);
insert into app.article_variants(id, article_id, size, active, sort_order) values
  ('cb400000-0000-4000-8000-000000000001', 'cb300000-0000-4000-8000-000000000001', '152', true, 1),
  ('cb400000-0000-4000-8000-000000000002', 'cb300000-0000-4000-8000-000000000002', '152', true, 1);
insert into app.article_seasons(article_id, season_id) values
  ('cb300000-0000-4000-8000-000000000001', 'cb100000-0000-4000-8000-000000000001'),
  ('cb300000-0000-4000-8000-000000000002', 'cb100000-0000-4000-8000-000000000001');
insert into app.member_orders(id, member_id, season_id, amount_due_cents) values
  ('cb500000-0000-4000-8000-000000000002', 'cb200000-0000-4000-8000-000000000002', 'cb100000-0000-4000-8000-000000000001', 9100),
  ('cb500000-0000-4000-8000-000000000003', 'cb200000-0000-4000-8000-000000000003', 'cb100000-0000-4000-8000-000000000001', 8750);
insert into app.order_lines(order_id, article_variant_id, quantity)
values('cb500000-0000-4000-8000-000000000002', 'cb400000-0000-4000-8000-000000000001', 1);
insert into app.payments(order_id, method, status, amount_cents, idempotency_key, paid_at)
values('cb500000-0000-4000-8000-000000000003', 'card', 'paid', 8750, 'bulk-paid-order', timezone('utc', now()));

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"cb000000-0000-4000-8000-000000000002","aal":"aal2"}', true);

select is((app.preview_team_order_articles(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid]
)->>'linesAdded')::integer, 3, 'preview telt alleen ontbrekende regels voor geschikte leden');
select is((app.preview_team_order_articles(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid]
)->>'paidOrdersSkipped')::integer, 1, 'preview slaat betaalde bestellingen over');
select is((app.preview_team_order_articles(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid]
)->>'inactiveMembersSkipped')::integer, 1, 'preview slaat inactieve leden over');

select throws_ok($$select app.bulk_add_team_order_articles_v2(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid],
  'cb100000-0000-4000-8000-000000000001', repeat('0', 64), null
)$$, '40001', 'TEAM_BULK_SNAPSHOT_CHANGED', 'commit met een verouderde snapshot wordt geweigerd');

select set_config('test.team_bulk_revision', app.preview_team_order_articles_v2(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid]
)->>'revision', false);
reset role;
update app.seasons set default_amount_cents = 8850 where id = 'cb100000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"cb000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok($$select app.bulk_add_team_order_articles_v2(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid],
  'cb100000-0000-4000-8000-000000000001', current_setting('test.team_bulk_revision'), null
)$$, '40001', 'TEAM_BULK_SNAPSHOT_CHANGED', 'gewijzigd standaardbedrag maakt de artikelpreview ongeldig');
reset role;
update app.seasons set default_amount_cents = 8750 where id = 'cb100000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"cb000000-0000-4000-8000-000000000002","aal":"aal2"}', true);

select lives_ok($$select app.bulk_add_team_order_articles_v2(
  'JO15-BULK',
  array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid],
  (app.preview_team_order_articles_v2('JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid])->>'seasonId')::uuid,
  app.preview_team_order_articles_v2('JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000002'::uuid])->>'revision',
  'cbf00000-0000-4000-8000-000000000001'
)$$, 'kledingcommissie kan artikelen veilig aan een team toevoegen');
select is((select amount_due_cents from app.member_orders where member_id = 'cb200000-0000-4000-8000-000000000001'), 8750, 'nieuwe order gebruikt het standaardbedrag');
select is((select amount_due_cents from app.member_orders where member_id = 'cb200000-0000-4000-8000-000000000002'), 9100, 'bestaand exact orderbedrag blijft behouden');
select is((select count(*)::integer from app.order_lines where order_id = 'cb500000-0000-4000-8000-000000000002' and status <> 'cancelled'), 2, 'bestaande maatregel blijft staan en alleen ontbrekend artikel wordt toegevoegd');
select is((select count(*)::integer from app.order_lines where order_id = 'cb500000-0000-4000-8000-000000000003'), 0, 'betaalde bestelling blijft onaangeraakt');
select ok(not exists(select 1 from app.member_orders where member_id = 'cb200000-0000-4000-8000-000000000004'), 'inactief lid krijgt geen bestelling');
select ok(exists(select 1 from app.audit_logs where action = 'order.team_bulk_articles_completed' and correlation_id = 'cbf00000-0000-4000-8000-000000000001'), 'teamtoewijzing is geaudit');
select is(jsonb_array_length((select metadata->'addedVariantIds' from app.audit_logs where action = 'order.team_bulk_articles_added' and entity_id = 'cb500000-0000-4000-8000-000000000002' order by id desc limit 1)), 1, 'orderaudit bevat uitsluitend werkelijk toegevoegde varianten');

select is((app.preview_team_member_status('JO15-BULK', false)->>'changedMembers')::integer, 3, 'statuspreview telt alleen leden die wijzigen');
select throws_ok($$select app.bulk_set_team_member_status_v2(
  'JO15-BULK', false, null, 'cb100000-0000-4000-8000-000000000001', repeat('0', 64), null
)$$, '22023', 'TEAM_STATUS_INPUT_INVALID', 'null auditreden wordt ook bij directe RPC-aanroep geweigerd');
select lives_ok($$select app.bulk_set_team_member_status_v2(
  'JO15-BULK', false, 'Team afgemeld voor dit seizoen',
  (app.preview_team_member_status_v2('JO15-BULK', false)->>'seasonId')::uuid,
  app.preview_team_member_status_v2('JO15-BULK', false)->>'revision',
  'cbf00000-0000-4000-8000-000000000002'
)$$, 'team kan in bulk inactief worden gemaakt');
select is((select count(*)::integer from app.members where team = 'JO15-BULK' and active_for_season), 0, 'alle teamleden zijn inactief');
select is((select count(*)::integer from app.audit_logs where action = 'member.deactivated' and correlation_id = 'cbf00000-0000-4000-8000-000000000002'), 3, 'ieder gewijzigd lid heeft een auditregel');
select ok(exists(select 1 from app.member_orders where id = 'cb500000-0000-4000-8000-000000000003'), 'statusbulk bewaart betaalde historie');

select throws_ok($$select app.preview_team_order_articles(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid, 'cb400000-0000-4000-8000-000000000001'::uuid]
)$$, '22023', 'TEAM_ARTICLE_INPUT_INVALID', 'dubbele varianten worden geweigerd');

select set_config('request.jwt.claims', '{"sub":"cb000000-0000-4000-8000-000000000003","aal":"aal2"}', true);
select throws_ok($$select app.preview_team_member_status('JO15-BULK', true)$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifte kan geen teamstatus bekijken');
select throws_ok($$select app.bulk_add_team_order_articles_v2(
  'JO15-BULK', array['cb400000-0000-4000-8000-000000000001'::uuid],
  'cb100000-0000-4000-8000-000000000001', repeat('0', 64), null
)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifte kan geen teamartikelen toevoegen');

select set_config('request.jwt.claims', '{"sub":"cb000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok($$select app.bulk_set_team_member_status_v2(
  'JO15-BULK', true, 'Niet toegestaan op AAL1',
  'cb100000-0000-4000-8000-000000000001', repeat('0', 64), null
)$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'AAL1 kan geen teamstatus wijzigen');

reset role;
select ok(not has_function_privilege('authenticated', 'app.bulk_set_team_member_status(text,boolean,text,uuid)', 'execute'), 'oude statuscommit is niet meer rechtstreeks uitvoerbaar');
select ok(not has_function_privilege('authenticated', 'app.bulk_add_team_order_articles(text,uuid[],uuid)', 'execute'), 'oude artikelcommit is niet meer rechtstreeks uitvoerbaar');

select * from finish();
rollback;
