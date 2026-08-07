begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('e0000000-0000-4000-8000-000000000001', 'Export beheerder', 'beheerder'),
  ('e0000000-0000-4000-8000-000000000002', 'Export commissie', 'kledingcommissie'),
  ('e0000000-0000-4000-8000-000000000003', 'Export uitgifte', 'uitgifte');

insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season) values
  ('e1000000-0000-4000-8000-000000000001', 'EXP-001', '=2+2', 'Voorbeeld', 'formule@example.invalid', 'JO15-1', true),
  ('e1000000-0000-4000-8000-000000000002', 'EXP-002', 'Inactief', 'Voorbeeld', 'inactief@example.invalid', 'JO17-2', false);

insert into app.articles(id, name, code, icon_type, sort_order) values
  ('e2000000-0000-4000-8000-000000000001', 'Export shirt', 'EXP-SHIRT', 'shirt', 301),
  ('e2000000-0000-4000-8000-000000000002', 'Export broek', 'EXP-BROEK', 'circle-dot', 302),
  ('e2000000-0000-4000-8000-000000000003', 'Export sokken', 'EXP-SOK', 'package', 303);
insert into app.article_variants(id, article_id, size, sku, sort_order) values
  ('e3000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '152', 'EXP-152', 1),
  ('e3000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000002', 'M', 'EXP-M', 1),
  ('e3000000-0000-4000-8000-000000000003', 'e2000000-0000-4000-8000-000000000003', '39-42', 'EXP-39', 1);
insert into app.article_seasons(article_id, season_id)
select article_id, settings.active_season_id
from unnest(array[
  'e2000000-0000-4000-8000-000000000001'::uuid,
  'e2000000-0000-4000-8000-000000000002'::uuid,
  'e2000000-0000-4000-8000-000000000003'::uuid
]) article_id
cross join app.app_settings settings
where settings.id = true;

insert into app.member_orders(id, member_id, season_id, amount_due_cents, order_status)
select 'e4000000-0000-4000-8000-000000000001'::uuid, 'e1000000-0000-4000-8000-000000000001'::uuid,
  active_season_id, 12500, 'Gedeeltelijk afgehaald' from app.app_settings where id = true
union all
select 'e4000000-0000-4000-8000-000000000002'::uuid, 'e1000000-0000-4000-8000-000000000002'::uuid,
  active_season_id, 12500, 'Nog niet betaald' from app.app_settings where id = true;

insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
) values (
  'e0500000-0000-4000-8000-000000000001',
  'Export ander seizoen',
  '2027-07-01',
  '2028-06-30',
  13000,
  'open',
  timezone('utc', now())
);
insert into app.member_orders(
  id, member_id, season_id, amount_due_cents, order_status
) values (
  'e4000000-0000-4000-8000-000000000003',
  'e1000000-0000-4000-8000-000000000002',
  'e0500000-0000-4000-8000-000000000001',
  13000,
  'Nog niet betaald'
);

insert into app.order_lines(id, order_id, article_variant_id, quantity, status) values
  ('e5000000-0000-4000-8000-000000000001', 'e4000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 1, 'backorder'),
  ('e5000000-0000-4000-8000-000000000002', 'e4000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000002', 1, 'ready_for_pickup'),
  ('e5000000-0000-4000-8000-000000000003', 'e4000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000003', 1, 'picked_up'),
  ('e5000000-0000-4000-8000-000000000004', 'e4000000-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000001', 2, 'backorder');

insert into app.payments(
  id, order_id, method, status, amount_cents, idempotency_key, paid_at,
  provider_payment_id, checkout_url
) values (
  'e6000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'cash', 'paid', 12500, 'export-payment-reference',
  timezone('utc', now()) - interval '1 day', null,
  'https://www.mollie.com/checkout/must-not-export'
);
insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
values(
  'e0000000-0000-4000-8000-000000000002',
  'payment.manual.recorded',
  'member_order',
  'e4000000-0000-4000-8000-000000000001',
  jsonb_build_object('payment_id', 'e6000000-0000-4000-8000-000000000001'::uuid)
);
insert into private.qr_tokens(order_id, token_hash, version, created_by)
values(
  'e4000000-0000-4000-8000-000000000001',
  repeat('e', 64),
  1,
  'e0000000-0000-4000-8000-000000000002'
);

insert into app.delivery_receipts(
  id, received_on, supplier, packing_slip_reference, actor_user_id
) values (
  'e7000000-0000-4000-8000-000000000001',
  current_date - 2,
  'Export leverancier',
  'EXP-PAK-001',
  'e0000000-0000-4000-8000-000000000002'
);
insert into app.delivery_receipt_lines(
  id, receipt_id, article_variant_id, received_quantity
) values
  ('e7100000-0000-4000-8000-000000000001', 'e7000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000002', 5),
  ('e7100000-0000-4000-8000-000000000002', 'e7000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000003', 1);
insert into app.inventory_reservations(
  id, receipt_line_id, order_line_id, quantity, status, actor_user_id
) values
  ('e7200000-0000-4000-8000-000000000001', 'e7100000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000002', 1, 'reserved', 'e0000000-0000-4000-8000-000000000002'),
  ('e7200000-0000-4000-8000-000000000002', 'e7100000-0000-4000-8000-000000000002', 'e5000000-0000-4000-8000-000000000003', 1, 'fulfilled', 'e0000000-0000-4000-8000-000000000003');
insert into app.fulfilments(
  id, order_id, actor_user_id, location, created_at
) values (
  'e8000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000003',
  'Clubhuis',
  timezone('utc', now()) - interval '12 hours'
);
insert into app.fulfilment_lines(
  id, fulfilment_id, order_line_id, reservation_id, quantity, created_at
) values (
  'e8100000-0000-4000-8000-000000000001',
  'e8000000-0000-4000-8000-000000000001',
  'e5000000-0000-4000-8000-000000000003',
  'e7200000-0000-4000-8000-000000000002',
  1,
  timezone('utc', now()) - interval '12 hours'
);

insert into private.parent_accounts(id, email_normalized)
values('e9000000-0000-4000-8000-000000000001', 'formule@example.invalid');
insert into private.parent_member_links(parent_account_id, member_id)
values('e9000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001');

select ok(has_function_privilege('authenticated', 'app.get_export_workspace()', 'EXECUTE'),
  'authenticated mag het smalle exportworkspacecontract aanroepen');
select ok(has_function_privilege('authenticated', 'app.create_export(text,uuid,text)', 'EXECUTE'),
  'authenticated mag create_export uitsluitend via interne rolcontrole aanroepen');
select ok(not has_function_privilege('anon', 'app.get_export_workspace()', 'EXECUTE'),
  'anon heeft geen exportworkspace');
select ok(not has_function_privilege('anon', 'app.create_export(text,uuid,text)', 'EXECUTE'),
  'anon kan geen export genereren');

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000003","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$select app.get_export_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan exportworkspace niet openen');
select throws_ok($$select app.create_export('members', null, 'all')$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan geen export genereren');

reset role;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000002","aal":"aal1"}', true);
set local role authenticated;
select throws_ok($$select app.get_export_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan exportworkspace niet openen');
select throws_ok($$select app.create_export('orders', null, 'all')$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan geen export genereren');

reset role;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select lives_ok($$select app.get_export_workspace()$$,
  'AAL2 beheerder kan exportworkspace openen');

reset role;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
create temporary table export_workspace_result as
select app.get_export_workspace() result;
create temporary table export_results(type text primary key, result jsonb);
grant select on export_workspace_result to authenticated;
grant select, insert on export_results to authenticated;

select is(
  (select result->'types' from export_workspace_result),
  '["members","orders","package_orders","package_items","payments","deliveries","fulfilments","outstanding"]'::jsonb,
  'workspace bevat exact de zes legacy- en twee pakkettypekeys in applicatievolgorde'
);
select is(
  (select array_agg(key order by key) from export_workspace_result,
    lateral jsonb_object_keys(result) key),
  array['filters','seasons','types']::text[],
  'workspace heeft exact types, seasons en filters'
);
select is(
  (select array_agg(key order by key) from export_workspace_result,
    lateral jsonb_object_keys(result->'filters') key),
  array['deliveries','fulfilments','members','orders','outstanding','package_items','package_orders','payments']::text[],
  'workspacefiltermap heeft exact de acht typekeys'
);
select ok(
  not exists(
    select 1
    from export_workspace_result workspace,
      lateral jsonb_each(workspace.result->'filters') filter_group,
      lateral jsonb_array_elements(filter_group.value) option
    where (select array_agg(key order by key) from jsonb_object_keys(option) key)
      <> array['label','value']::text[]
      or jsonb_typeof(option->'value') <> 'string'
      or jsonb_typeof(option->'label') <> 'string'
  ),
  'ieder filter is strikt een object met primitieve value en label'
);
select ok(
  not exists(
    select 1
    from export_workspace_result workspace,
      lateral jsonb_each(workspace.result->'filters') filter_group
    where filter_group.value->0->>'value' <> 'all'
  ),
  'iedere filterallowlist begint met all'
);
select ok(
  (select bool_or((season->>'active')::boolean)
   from export_workspace_result,
     lateral jsonb_array_elements(result->'seasons') season),
  'workspace markeert exact bruikbaar een actief seizoen'
);

insert into export_results(type, result)
select 'members', app.create_export('members', (select active_season_id from app.app_settings where id = true), null)
union all
select 'orders', app.create_export('orders', (select active_season_id from app.app_settings where id = true), '')
union all
select 'package_orders', app.create_export('package_orders', (select active_season_id from app.app_settings where id = true), 'all')
union all
select 'package_items', app.create_export('package_items', (select active_season_id from app.app_settings where id = true), 'all')
union all
select 'payments', app.create_export('payments', (select active_season_id from app.app_settings where id = true), 'all')
union all
select 'deliveries', app.create_export('deliveries', (select active_season_id from app.app_settings where id = true), 'all')
union all
select 'fulfilments', app.create_export('fulfilments', (select active_season_id from app.app_settings where id = true), 'all')
union all
select 'outstanding', app.create_export('outstanding', (select active_season_id from app.app_settings where id = true), 'all');

select is((select count(*) from export_results), 8::bigint,
  'alle zes legacy- en twee pakketexporttypes leveren een payload');
select ok(not exists(
  select 1 from export_results
  where (select array_agg(key order by key) from jsonb_object_keys(result) key)
    <> array['columns','generatedAt','rows','seasonName','type']::text[]
), 'ieder exportresultaat heeft exact het strikte applicatiecontract');
select ok(not exists(
  select 1
  from export_results result_set,
    lateral jsonb_array_elements(result_set.result->'columns') column_definition
  where (select array_agg(key order by key) from jsonb_object_keys(column_definition) key)
    <> array['key','label']::text[]
), 'iedere kolomdefinitie bevat exact key en label');
select ok(not exists(
  select 1
  from export_results result_set,
    lateral jsonb_array_elements(result_set.result->'rows') row_value,
    lateral jsonb_each(row_value) field
  where jsonb_typeof(field.value) in ('array', 'object')
), 'alle rijvelden zijn uitsluitend string, number, boolean of null');
select ok(not exists(
  select 1 from export_results
  where result->>'generatedAt' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
), 'generatedAt is voor alle exports een ISO UTC-string');
select ok(not exists(
  select 1 from export_results where jsonb_array_length(result->'rows') = 0
), 'de fixture vult alle acht exporttypes');

select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'members'),
  array['relationNumber','name','team','email','active','parentLinked']::text[],
  'ledenexport heeft exact de canonieke minimale kolommen'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'orders'),
  array['member','season','amountCents','paymentStatus','orderStatus','backorderQuantity','readyForPickupQuantity','pickedUpQuantity','cancelledQuantity']::text[],
  'bestellingenexport heeft betaal-, order- en artikelstatuskolommen'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'package_orders'),
  array[
    'relationNumber','member','team','season','order','packageName',
    'packageRevision','packagePriceCents','currency','snapshotOrigin',
    'paymentStatus','orderStatus','componentCount','sizeMissingCount',
    'backorderQuantity','readyForPickupQuantity','pickedUpQuantity'
  ]::text[],
  'pakketorderexport bevat immutable commerciële snapshot en operationele tellingen'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'package_items'),
  array[
    'relationNumber','member','team','season','order','packageName',
    'packageRevision','productName','productCode','quantity','selectedSize',
    'lineStatus','issuedQuantity','issuedSizes','paymentStatus'
  ]::text[],
  'pakketonderdelenexport bevat product-, maat-, status- en uitgiftesnapshots'
);
select ok(
  (select result->'rows' from export_results where type = 'package_orders')
    @> '[{"packageName":"Legacy tenue","packageRevision":"legacy-v1","packagePriceCents":12500,"currency":"EUR","snapshotOrigin":"legacy"}]'::jsonb,
  'pakketorderexport leest naam, revisie, prijs en valuta uit de commerciële snapshot'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'payments'),
  array['order','member','amountCents','method','status','reference','date','actor']::text[],
  'betalingenexport heeft exact de canonieke minimale kolommen'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'deliveries'),
  array['delivery','date','variant','received','reserved','available']::text[],
  'leveringenexport heeft exact de actuele receipt-kolommen'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'fulfilments'),
  array['member','line','article','size','date','actorRole','actor','correctionStatus']::text[],
  'uitgifte-export heeft exact regel-, actor- en correctiekolommen'
);
select is(
  (select array_agg(column_definition->>'key' order by ordinal)
   from export_results,
     lateral jsonb_array_elements(result->'columns') with ordinality columns(column_definition, ordinal)
   where type = 'outstanding'),
  array['member','relationNumber','season','order','category','article','size','quantity','paymentStatus','lineStatus']::text[],
  'openstaandexport dekt niet betaald, nalevering en nog af te halen'
);

select ok(exists(
  select 1 from export_results,
    lateral jsonb_array_elements(result->'rows') row_value
  where type = 'members' and row_value->>'name' = '=2+2 Voorbeeld'
), 'formulebeginnende brontekst blijft rauw voor escaping in de applicatielaag');
select ok((select result::text from export_results where type = 'payments') not like '%must-not-export%',
  'checkout-URL lekt niet in de betalingenexport');
select ok((select string_agg(result::text, '') from export_results) not like '%' || repeat('e', 64) || '%',
  'QR-tokenhash lekt in geen enkele export');
select ok((select string_agg(result::text, '') from export_results) !~ '(code_hash|token_hash|idempotency_key|payload)',
  'exportcontract bevat geen secret- of providerpayloadvelden');

select is(jsonb_array_length(app.create_export('members', (select active_season_id from app.app_settings where id = true), 'active')->'rows'), 1,
  'ledenfilter active wordt server-side toegepast');
select is(jsonb_array_length(app.create_export('orders', (select active_season_id from app.app_settings where id = true), 'paid')->'rows'), 1,
  'bestellingenfilter paid wordt server-side toegepast');
select is(jsonb_array_length(app.create_export('package_orders', (select active_season_id from app.app_settings where id = true), 'paid')->'rows'), 1,
  'pakketorderfilter paid gebruikt uitsluitend betaling op de actieve pakketsnapshot');
select is(jsonb_array_length(app.create_export('package_orders', (select active_season_id from app.app_settings where id = true), 'legacy')->'rows'), 2,
  'pakketorderfilter legacy wordt server-side toegepast');
select is(jsonb_array_length(app.create_export('package_items', (select active_season_id from app.app_settings where id = true), 'issued')->'rows'), 1,
  'pakketonderdelenfilter issued gebruikt actieve immutable uitgifteregels');
select is(jsonb_array_length(app.create_export('payments', (select active_season_id from app.app_settings where id = true), 'cash')->'rows'), 1,
  'betalingenfilter cash wordt server-side toegepast');
select is(jsonb_array_length(app.create_export('deliveries', (select active_season_id from app.app_settings where id = true), 'fully_allocated')->'rows'), 1,
  'leveringenfilter fully_allocated gebruikt actuele reserveringen');
select is(jsonb_array_length(app.create_export('fulfilments', (select active_season_id from app.app_settings where id = true), 'active')->'rows'), 1,
  'uitgiftefilter active gebruikt actuele correctiestatus');
select is(jsonb_array_length(app.create_export('outstanding', (select active_season_id from app.app_settings where id = true), 'backorder')->'rows'), 2,
  'openstaandfilter backorder levert uitsluitend naleveringsregels');
select throws_ok($$select app.create_export('members', null, 'email like %')$$,
  '22023', 'INVALID_EXPORT_FILTER', 'willekeurige browserfilterexpressie wordt geweigerd');
select throws_ok($$select app.create_export('unknown', null, 'all')$$,
  '22023', 'INVALID_EXPORT_TYPE', 'niet-canoniek exporttype wordt geweigerd');
select throws_ok($$select app.create_export('package_items', null, 'product like %')$$,
  '22023', 'INVALID_EXPORT_FILTER',
  'pakketexport weigert willekeurige browserfilterexpressies');

select is(
  jsonb_array_length(app.create_export(
    'package_orders',
    (select active_season_id from app.app_settings where id = true),
    'all'
  )->'rows'),
  2,
  'pakketorderexport is strikt aan het gekozen seizoen gebonden'
);
select throws_ok(
  $$select app.create_export('package_orders', null, 'all')$$,
  '22023',
  'EXPORT_SEASON_REQUIRED',
  'een export zonder expliciet seizoen wordt geweigerd'
);

reset role;
update app.articles
set name = 'Hernoemd live catalogusproduct'
where id = 'e2000000-0000-4000-8000-000000000003';
set local role authenticated;

select ok(
  app.create_export('package_items', (select active_season_id from app.app_settings where id = true), 'issued')->'rows'
    @> '[{"productName":"Export sokken","selectedSize":"39-42","issuedSizes":"39-42"}]'::jsonb,
  'pakketonderdelen blijven na cataloguswijziging op product- en uitgiftesnapshots'
);
select ok(
  app.create_export('fulfilments', (select active_season_id from app.app_settings where id = true), 'active')->'rows'
    @> '[{"article":"Export sokken","size":"39-42"}]'::jsonb,
  'uitgifte-export gebruikt fulfilment-snapshots en niet de live catalogus'
);

reset role;
select ok(not exists(
  select 1 from app.audit_logs audit
  where audit.action = 'export.created'
    and (select array_agg(key order by key) from jsonb_object_keys(audit.metadata) key)
      <> array['filter','row_count','season','type']::text[]
), 'exportaudit bevat uitsluitend type, seizoen, filter en rijcount');
select ok(not exists(
  select 1 from app.audit_logs audit
  where audit.action = 'export.created'
    and audit.metadata::text ~ '(formule@example|must-not-export|token|payload)'
), 'exportaudit bevat geen rijdata, e-mail, token of payload');
select ok(not exists(
  select 1 from private.rate_limit_events
  where scope = 'export' and key_hash !~ '^[0-9a-f]{64}$'
), 'export rate-limit bewaart uitsluitend gehashte sleutels');

insert into app.members(relation_number, first_name, last_name, email, team, active_for_season)
select 'EXP-CAP-' || lpad(value::text, 5, '0'), 'Capaciteit', value::text,
  'export-cap-' || value || '@example.invalid', 'CAP', false
from generate_series(1, 10001) value;
insert into app.member_orders(member_id, season_id, amount_due_cents, order_status)
select member.id, settings.active_season_id, 0, 'Nog niet betaald'
from app.members member
cross join app.app_settings settings
where member.relation_number like 'EXP-CAP-%'
  and settings.id = true;

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$select app.create_export('members', (select active_season_id from app.app_settings where id = true), 'inactive')$$,
  '54000', 'EXPORT_CAPACITY_EXCEEDED', 'export stopt fail-closed boven 10.000 rijen');

reset role;
select * from finish();
rollback;
