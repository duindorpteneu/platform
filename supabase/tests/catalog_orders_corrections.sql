begin;

create extension if not exists pgtap with schema extensions;
select plan(38);

insert into app.staff_profiles(auth_user_id, display_name, role)
values
  ('a0000000-0000-4000-8000-000000000001', 'Sprint commissie', 'kledingcommissie'),
  ('a0000000-0000-4000-8000-000000000002', 'Sprint uitgifte', 'uitgifte');

insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season)
values
  ('a1000000-0000-4000-8000-000000000001', 'SPRINT-001', 'Sophie', 'Sprint', 'sophie-sprint@example.invalid', 'JO13-1', true),
  ('a1000000-0000-4000-8000-000000000002', 'SPRINT-002', 'Inactief', 'Sprint', 'inactief-sprint@example.invalid', 'JO15-1', false);

insert into app.articles(id, name, code, icon_type, sort_order)
values
  ('a2000000-0000-4000-8000-000000000001', 'Sprintshirt', 'SPRINT-SHIRT', 'shirt', 101),
  ('a2000000-0000-4000-8000-000000000002', 'Sprintbroek', 'SPRINT-BROEK', 'circle-dot', 102);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values
  ('a3000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000001', 'M', 'SPRINT-M', 1),
  ('a3000000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000002', '152', 'SPRINT-152', 1);
insert into app.article_seasons(article_id, season_id)
select article_id, (select active_season_id from app.app_settings where id = true)
from (values
  ('a2000000-0000-4000-8000-000000000001'::uuid),
  ('a2000000-0000-4000-8000-000000000002'::uuid)
) input(article_id);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok(
  $$select app.get_catalog_order_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan catalogus en bestellingen niet openen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select app.get_catalog_order_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan catalogus en bestellingen niet openen'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select ok(position('email' in app.get_catalog_order_workspace()::text) = 0, 'workspace bevat geen e-mailadres');
select lives_ok(
  $$select app.upsert_catalog_article(null, 'Trainingsjack', 'JACK', 'package', true, 110, array[(select active_season_id from app.app_settings where id = true)])$$,
  'kledingcommissie kan een artikel met seizoen toevoegen'
);
select lives_ok(
  $$select app.upsert_catalog_variant((select id from app.articles where code = 'JACK'), null, '164', 'JACK-164', true, 1)$$,
  'kledingcommissie kan een variant toevoegen'
);
select throws_ok(
  $$select app.save_member_order(
    'a1000000-0000-4000-8000-000000000002',
    (select active_season_id from app.app_settings where id = true),
    12500,
    '[{"variant_id":"a3000000-0000-4000-8000-000000000001","quantity":1}]'::jsonb
  )$$, '23514', 'MEMBER_NOT_ACTIVE', 'inactief lid kan geen nieuwe bestelling krijgen'
);

create temporary table saved_order as
select app.save_member_order(
  'a1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id = true),
  12500,
  '[{"variant_id":"a3000000-0000-4000-8000-000000000001","quantity":1},{"variant_id":"a3000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb
) result;

select is((result->>'lineCount')::integer, 2, 'bestelling bewaart twee artikelregels') from saved_order;
select is((select amount_due_cents from app.member_orders where id = (select (result->>'orderId')::uuid from saved_order)), 12500, 'exact bedrag staat in eurocenten');
select is((select count(*)::integer from app.order_lines where order_id = (select (result->>'orderId')::uuid from saved_order) and status <> 'cancelled'), 2, 'één actieve regel per gekozen artikel');
select throws_ok(
  $$select app.save_member_order(
    'a1000000-0000-4000-8000-000000000001',
    (select active_season_id from app.app_settings where id = true),
    12500,
    '[{"variant_id":"a3000000-0000-4000-8000-000000000001","quantity":1},{"variant_id":"a3000000-0000-4000-8000-000000000001","quantity":2}]'::jsonb
  )$$, '22023', 'INVALID_ORDER_LINES', 'dubbele varianten en artikelen worden geblokkeerd'
);
select lives_ok(
  $$select app.save_member_order(
    'a1000000-0000-4000-8000-000000000001',
    (select active_season_id from app.app_settings where id = true),
    13000,
    '[{"variant_id":"a3000000-0000-4000-8000-000000000001","quantity":1},{"variant_id":"a3000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb
  )$$, 'bedrag kan vóór betaling worden aangepast'
);

reset role;
select throws_ok(
  $$insert into app.payments(order_id, method, status, amount_cents, idempotency_key)
    values((select (result->>'orderId')::uuid from saved_order), 'card', 'paid', 1, 'wrong-paid-amount')$$,
  '23514', 'PAID_AMOUNT_MISMATCH', 'paid vereist exact orderbedrag op tabelniveau'
);
select ok(not has_function_privilege('authenticated', 'app.record_manual_payment_with_qr_trusted(uuid,uuid,app.payment_method,text,text)', 'EXECUTE'), 'trusted betaal-RPC is niet voor authenticated');
select ok(not has_function_privilege('service_role', 'app.record_manual_payment_with_qr_trusted(uuid,uuid,app.payment_method,text,text)', 'EXECUTE'), 'legacy trusted betaal-RPC is ook voor service role ingetrokken');
select ok(has_function_privilege('authenticated', 'app.record_manual_payment_v2(uuid,app.payment_method,integer,text,uuid,uuid)', 'EXECUTE'), 'nieuwe kas-RPC valideert beheerder en AAL2 in de database');
select throws_ok(
  $$select app.record_manual_payment_with_qr_trusted(
    'a0000000-0000-4000-8000-000000000001',
    (select (result->>'orderId')::uuid from saved_order), 'mollie', 'manual-mollie-invalid', repeat('a',64)
  )$$, '22023', 'INVALID_MANUAL_PAYMENT', 'handmatige trusted RPC weigert mollie'
);
select lives_ok(
  $$select app.record_manual_payment_with_qr_trusted(
    'a0000000-0000-4000-8000-000000000001',
    (select (result->>'orderId')::uuid from saved_order), 'card', 'manual-card-sprint', repeat('a',64)
  )$$, 'exacte handmatige betaling en eerste QR worden transactioneel opgeslagen'
);
select is((select amount_cents from app.payments where idempotency_key = 'manual-card-sprint'), 13000, 'handmatige betaling gebruikt het actuele exacte bedrag');
select is((select version from private.qr_tokens where order_id = (select (result->>'orderId')::uuid from saved_order) and active), 1, 'eerste betaalde QR heeft versie één');
select throws_ok(
  $$update app.member_orders set amount_due_cents = 14000 where id = (select (result->>'orderId')::uuid from saved_order)$$,
  '23514', 'PAID_ORDER_IMMUTABLE', 'betaald orderbedrag is ook buiten de route immutable'
);

set local role authenticated;
select throws_ok(
  $$select app.save_member_order(
    'a1000000-0000-4000-8000-000000000001',
    (select active_season_id from app.app_settings where id = true),
    13000,
    '[{"variant_id":"a3000000-0000-4000-8000-000000000001","quantity":2},{"variant_id":"a3000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb
  )$$, '23514', 'PAID_ORDER_IMMUTABLE', 'normale orderbewerking na betaling is geblokkeerd'
);
select throws_ok(
  $$select app.upsert_catalog_variant('a2000000-0000-4000-8000-000000000001', 'a3000000-0000-4000-8000-000000000001', 'L', 'SPRINT-L', true, 1)$$,
  '23514', 'USED_VARIANT_SIZE_IMMUTABLE', 'gebruikte maathistorie kan niet worden herschreven'
);
reset role;
select ok(not has_function_privilege('authenticated', 'app.store_order_qr(uuid,text,integer)', 'EXECUTE'), 'oude caller-supplied QR-RPC is ingetrokken');
select ok(has_schema_privilege('service_role', 'app', 'USAGE'), 'service role kan uitsluitend gegrante app-RPCs bereiken');
select ok(not has_function_privilege('authenticated', 'app.get_order_qr_rotation_context(uuid,uuid)', 'EXECUTE'), 'QR-versiecontext is niet direct voor authenticated');
select ok(not has_function_privilege('service_role', 'app.get_order_qr_rotation_context(uuid,uuid)', 'EXECUTE'), 'oude QR-versiecontext is ook voor service role ingetrokken');
select ok(not has_function_privilege('authenticated', 'app.rotate_order_qr(uuid,uuid,integer,text,text)', 'EXECUTE'), 'QR-rotatie accepteert hashes alleen via service role');
select ok(not has_function_privilege('service_role', 'app.rotate_order_qr(uuid,uuid,integer,text,text)', 'EXECUTE'), 'oude QR-rotatie is ook voor service role ingetrokken');
select ok(not has_function_privilege('authenticated', 'app.lookup_fulfilment(text)', 'EXECUTE'), 'legacy bearerlookup is definitief ingetrokken');
select ok(not has_function_privilege('service_role', 'app.lookup_fulfilment(text)', 'EXECUTE'), 'legacy bearerlookup heeft geen serveromweg');
select ok(not has_function_privilege('authenticated', 'app.commit_fulfilment_v2(uuid,uuid[],text,text)', 'EXECUTE'), 'legacy uitgiftecommit is niet voor authenticated');
select ok(not has_function_privilege('service_role', 'app.commit_fulfilment_v2(uuid,uuid[],text,text)', 'EXECUTE'), 'legacy uitgiftecommit is ook server-side ingetrokken');
select ok(not has_function_privilege('authenticated', 'app.exchange_order_qr_locator_v2(uuid,text,text,text,integer,uuid)', 'EXECUTE'), 'browserrollen kunnen locator exchange niet rechtstreeks aanroepen');
select ok(has_function_privilege('service_role', 'app.exchange_order_qr_locator_v2(uuid,text,text,text,integer,uuid)', 'EXECUTE'), 'locator exchange is uitsluitend voor de serveradapter');
select ok(not has_function_privilege('authenticated', 'app.commit_fulfilment_v3(uuid,text,text,uuid[],uuid,uuid)', 'EXECUTE'), 'browserrollen kunnen v3-uitgifte niet rechtstreeks aanroepen');
select ok(has_function_privilege('service_role', 'app.commit_fulfilment_v3(uuid,text,text,uuid[],uuid,uuid)', 'EXECUTE'), 'v3-uitgifte is uitsluitend voor de serveradapter');
select ok(not has_function_privilege('authenticated', 'app.correct_fulfilment_v3(uuid,text,uuid[],text,text,uuid,uuid)', 'EXECUTE'), 'browserrollen kunnen journalcorrecties niet rechtstreeks aanroepen');
select ok(has_function_privilege('service_role', 'app.correct_fulfilment_v3(uuid,text,uuid[],text,text,uuid,uuid)', 'EXECUTE'), 'journalcorrecties zijn uitsluitend voor de serveradapter');

select * from finish();
rollback;
