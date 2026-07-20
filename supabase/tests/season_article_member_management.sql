begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role, active) values
  ('ca000000-0000-4000-8000-000000000001', 'Seizoen beheerder', 'beheerder', true),
  ('ca000000-0000-4000-8000-000000000002', 'Seizoen commissie', 'kledingcommissie', true),
  ('ca000000-0000-4000-8000-000000000003', 'Seizoen uitgifte', 'uitgifte', true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ca000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select lives_ok($$select app.create_season(
  '2038/2039 beheer', '2038-07-01', '2039-06-30', 9900, true,
  'caf00000-0000-4000-8000-000000000001'
)$$, 'beheerder kan een nieuw open seizoen aanmaken');
select is((select status::text from app.seasons where name = '2038/2039 beheer'), 'open', 'nieuw seizoen is open');
select is((select active_season_id from app.app_settings where id), (select id from app.seasons where name = '2038/2039 beheer'), 'nieuw seizoen kan direct actief worden');
select ok(exists(select 1 from app.audit_logs where action = 'season.created' and correlation_id = 'caf00000-0000-4000-8000-000000000001'), 'seizoenaanmaak is geaudit');
select is(app.audit_category('season.created'), 'settings', 'seizoenaudit valt in de beheercategorie');
select throws_ok($$select app.create_season(
  '2038/2039 beheer', '2038-07-01', '2039-06-30', 9900, false, null
)$$, '23505', 'SEASON_NAME_EXISTS', 'dubbele seizoensnaam wordt geweigerd');

reset role;
update app.app_settings set active_season_id = null where id = true;
set local role authenticated;
select lives_ok($$select app.create_season(
  '2039/2040 niet actief', '2039-07-01', '2040-06-30', 10100, false,
  'caf00000-0000-4000-8000-000000000004'
)$$, 'beheerder kan een seizoen bewust niet-actief aanmaken');
select is((select active_season_id from app.app_settings where id), null::uuid, 'niet-actief blijft exact gerespecteerd zonder bestaand actief seizoen');
select is((select metadata->>'madeActive' from app.audit_logs where correlation_id = 'caf00000-0000-4000-8000-000000000004'), 'false', 'audit bevat de werkelijk toegepaste activatiestatus');

reset role;
update app.app_settings set active_season_id = (select id from app.seasons where name = '2038/2039 beheer') where id = true;
insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season)
values('ca100000-0000-4000-8000-000000000001', 'SEIZOEN-001', 'Saar', 'Seizoen', 'saar-seizoen@example.invalid', 'JO11-1', true);
insert into app.articles(id, name, code, icon_type, sort_order) values
  ('ca200000-0000-4000-8000-000000000001', 'Seizoensshirt', 'SEIZ-SHIRT', 'shirt', 301),
  ('ca200000-0000-4000-8000-000000000002', 'Seizoensbroek', 'SEIZ-BROEK', 'package', 302);
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'ca300000-0000-4000-8000-000000000001', 'ca100000-0000-4000-8000-000000000001', id, 9900
from app.seasons where name = '2038/2039 beheer';
insert into app.seasons(id, name, starts_on, ends_on, default_amount_cents, status, opened_at, archived_at)
values('ca500000-0000-4000-8000-000000000001', '2037/2038 historie', '2037-07-01', '2038-06-30', 9500, 'archived', timezone('utc', now()) - interval '1 year', timezone('utc', now()));
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
values('ca300000-0000-4000-8000-000000000002', 'ca100000-0000-4000-8000-000000000001', 'ca500000-0000-4000-8000-000000000001', 9500);
insert into private.parent_accounts(id, email_normalized)
values('ca400000-0000-4000-8000-000000000001', 'saar-seizoen@example.invalid');
insert into private.parent_sessions(parent_account_id, token_hash, expires_at)
values('ca400000-0000-4000-8000-000000000001', repeat('c', 64), timezone('utc', now()) + interval '1 hour');
insert into private.parent_member_links(parent_account_id, member_id)
values('ca400000-0000-4000-8000-000000000001', 'ca100000-0000-4000-8000-000000000001');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ca000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select is(jsonb_array_length(app.get_catalog_seasons()), (select count(*)::integer from app.seasons), 'catalogus toont alle seizoenen');
select lives_ok($$select app.bulk_set_article_season(
  (select id from app.seasons where name = '2038/2039 beheer'),
  array['ca200000-0000-4000-8000-000000000001'::uuid, 'ca200000-0000-4000-8000-000000000002'::uuid],
  true, 'caf00000-0000-4000-8000-000000000002'
)$$, 'kledingcommissie kan artikelen in bulk koppelen');
select is((select count(*)::integer from app.article_seasons where season_id = (select id from app.seasons where name = '2038/2039 beheer')), 2, 'beide artikelen zijn gekoppeld');
select is(jsonb_array_length((select metadata->'articleIds' from app.audit_logs where correlation_id = 'caf00000-0000-4000-8000-000000000002')), 2, 'bulkaudit bewaart de twee gekozen artikel-ID’s');
select is(app.audit_category('catalog.article_seasons.bulk_linked'), 'inventory', 'catalogusmutatie valt in de operationele voorraadcategorie');
select lives_ok($$select app.bulk_set_article_season(
  (select id from app.seasons where name = '2038/2039 beheer'),
  array['ca200000-0000-4000-8000-000000000002'::uuid], false, null
)$$, 'kledingcommissie kan geselecteerde artikelen ontkoppelen');
select is((select count(*)::integer from app.article_seasons where season_id = (select id from app.seasons where name = '2038/2039 beheer')), 1, 'alleen geselecteerd artikel is ontkoppeld');

select lives_ok($$select app.set_member_active_for_season(
  'ca100000-0000-4000-8000-000000000001', false, 'Afgemeld voor dit seizoen',
  'caf00000-0000-4000-8000-000000000003'
)$$, 'kledingcommissie kan een lid inactief maken');
select ok(not (select active_for_season from app.members where id = 'ca100000-0000-4000-8000-000000000001'), 'lidstatus is inactief');
select ok(exists(select 1 from app.member_orders where id = 'ca300000-0000-4000-8000-000000000001'), 'bestaande bestelling blijft behouden');
select ok(exists(select 1 from app.audit_logs where action = 'member.deactivated' and correlation_id = 'caf00000-0000-4000-8000-000000000003'), 'inactiveren is met reden geaudit');

reset role;
select throws_ok($$select app.record_manual_payment_with_qr_trusted(
  'ca000000-0000-4000-8000-000000000002', 'ca300000-0000-4000-8000-000000000001',
  'card', 'inactive-member-payment', repeat('d', 64)
)$$, '23514', 'MEMBER_NOT_ACTIVE', 'inactief lid kan geen nieuwe handmatige betaling krijgen');
select throws_ok($$select public.prepare_mollie_payment(
  repeat('c', 64), 'ca300000-0000-4000-8000-000000000001', 'inactive-mollie-attempt'
)$$, '42501', 'PARENT_ORDER_ACCESS_DENIED', 'inactief lid kan geen nieuwe Mollie-betaling starten');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ca000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select lives_ok($$select app.set_member_active_for_season(
  'ca100000-0000-4000-8000-000000000001', true, 'Opnieuw aangemeld', null
)$$, 'kledingcommissie kan een lid opnieuw activeren');
select ok((select active_for_season from app.members where id = 'ca100000-0000-4000-8000-000000000001'), 'lidstatus is weer actief');
select throws_ok($$select app.create_season('Verboden', null, null, 9900, false, null)$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'kledingcommissie kan geen seizoen aanmaken');

select set_config('request.jwt.claims', '{"sub":"ca000000-0000-4000-8000-000000000003","aal":"aal2"}', true);
select throws_ok($$select app.bulk_set_article_season(
  (select id from app.seasons where name = '2038/2039 beheer'),
  array['ca200000-0000-4000-8000-000000000001'::uuid], true, null
)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifte kan geen artikelen koppelen');
select throws_ok($$select app.set_member_active_for_season(
  'ca100000-0000-4000-8000-000000000001', false, 'Niet toegestaan', null
)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifte kan geen lidstatus wijzigen');

reset role;
select throws_ok($$select app.record_manual_payment_with_qr_trusted(
  'ca000000-0000-4000-8000-000000000002', 'ca300000-0000-4000-8000-000000000002',
  'card', 'historical-member-payment', repeat('e', 64)
)$$, '23514', 'ORDER_SEASON_NOT_ACTIVE', 'heractivatie maakt een historische bestelling niet opnieuw handmatig betaalbaar');
select throws_ok($$select public.prepare_mollie_payment(
  repeat('c', 64), 'ca300000-0000-4000-8000-000000000002', 'historical-mollie-attempt'
)$$, '42501', 'PARENT_ORDER_ACCESS_DENIED', 'heractivatie maakt een historische bestelling niet opnieuw online betaalbaar');

select * from finish();
rollback;
