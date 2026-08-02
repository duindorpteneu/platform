begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('b0000000-0000-4000-8000-000000000001', 'Provider commissie', 'kledingcommissie'),
  ('b0000000-0000-4000-8000-000000000002', 'Provider uitgifte', 'uitgifte');

insert into app.members(id, relation_number, first_name, last_name, email, team) values
  ('b1000000-0000-4000-8000-000000000001', 'PROVIDER-001', 'Puck', 'Provider', 'puck-provider@example.invalid', 'JO15-1'),
  ('b1000000-0000-4000-8000-000000000002', 'PROVIDER-002', 'Mila', 'Handmatig', 'mila-manual@example.invalid', 'JO13-1');
insert into app.articles(id, name, code, icon_type, sort_order)
values('b2000000-0000-4000-8000-000000000001', 'Provider shirt', 'PROVIDER-SHIRT', 'shirt', 210);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values('b3000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001', 'M', 'PROVIDER-M', 1);
insert into app.article_seasons(article_id, season_id)
select 'b2000000-0000-4000-8000-000000000001', active_season_id from app.app_settings where id = true;
insert into app.member_orders(id, member_id, season_id, amount_due_cents) select
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', active_season_id, 7500
from app.app_settings where id = true;
insert into app.member_orders(id, member_id, season_id, amount_due_cents) select
  'b4000000-0000-4000-8000-000000000002', 'b1000000-0000-4000-8000-000000000002', active_season_id, 12500
from app.app_settings where id = true;
insert into app.order_lines(id, order_id, article_variant_id, quantity) values
  ('b5000000-0000-4000-8000-000000000001', 'b4000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000001', 1),
  ('b5000000-0000-4000-8000-000000000002', 'b4000000-0000-4000-8000-000000000002', 'b3000000-0000-4000-8000-000000000001', 1);

insert into private.parent_accounts(id, email_normalized)
values('b6000000-0000-4000-8000-000000000001', 'puck-provider@example.invalid');
insert into private.parent_sessions(parent_account_id, token_hash, expires_at)
values('b6000000-0000-4000-8000-000000000001', repeat('1', 64), timezone('utc', now()) + interval '1 hour');
insert into private.parent_member_links(parent_account_id, member_id)
values('b6000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001');
update private.parent_portal_grants
set status = 'active',
    source = 'administrator',
    granted_by = 'b0000000-0000-4000-8000-000000000001',
    granted_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where parent_account_id = 'b6000000-0000-4000-8000-000000000001'
  and status = 'review_required';

select is((select count(*) from app.email_templates), 7::bigint, 'zes legacytemplates plus de veilige portaaluitnodiging bestaan');
select is((select array_agg(template_key order by template_key) from app.email_templates),
  array['payment_received','payment_reminder','payment_request','portal_access_invite','qr_code_resent','ready_for_pickup','verification_code']::text[],
  'templatecontract bevat de portaaluitnodiging en alle zes legacykeys');
select is((select count(*) from app.email_templates where template_key = 'qr_resend'), 0::bigint,
  'niet-canonieke alias qr_resend bestaat niet');
select ok(not has_table_privilege('authenticated', 'app.email_templates', 'SELECT'), 'templates zijn alleen via smalle RPC leesbaar');
select ok(not has_table_privilege('authenticated', 'app.email_events', 'SELECT'), 'SendGrid-events zijn default-deny');
select ok(not has_table_privilege('authenticated', 'private.payment_events', 'SELECT'), 'payment-eventledger is default-deny');
select ok(not has_function_privilege('authenticated', 'public.prepare_mollie_payment(text,uuid,text)', 'EXECUTE'), 'Mollie prepare is service-only');
select ok(has_function_privilege('service_role', 'public.prepare_mollie_payment(text,uuid,text)', 'EXECUTE'), 'service role mag Mollie prepare uitvoeren');
select ok(not has_function_privilege('authenticated', 'app.claim_email_jobs(uuid,integer)', 'EXECUTE'), 'jobclaim is service-only');

create temporary table provider_template_ids as
select template_key, id from app.email_templates;
grant select on provider_template_ids to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok($$select app.get_email_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifterol kan e-mailworkspace niet openen');
select throws_ok($$select app.create_email_bulk('payment_reminder', array['b4000000-0000-4000-8000-000000000001'::uuid], 'issuance-bulk-denied')$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifterol kan geen bulkmail maken');
select throws_ok($$select app.update_email_template(
  (select id from provider_template_ids where template_key='payment_reminder'), 'Onderwerp', 'Veilige inhoud voor {{clubnaam}}', 1)$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifterol kan templates niet wijzigen');

reset role;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select lives_ok($$select app.get_email_workspace()$$, 'AAL2 kledingcommissie kan e-mailworkspace openen');
select throws_ok($$select app.update_email_template(
  (select id from provider_template_ids where template_key='payment_reminder'), 'Herinnering {{onbekend}}',
  'Dit is een veilige maar onbekende shortcode {{onbekend}}.', 1)$$,
  '22023', 'EMAIL_TEMPLATE_SHORTCODE_NOT_ALLOWED', 'onbekende shortcode wordt geweigerd');
select throws_ok($$select app.update_email_template(
  (select id from provider_template_ids where template_key='payment_reminder'), 'Veilig onderwerp',
  '<script>alert(1)</script> inhoud', 1)$$,
  '22023', 'INVALID_EMAIL_TEMPLATE_SOURCE', 'HTML en script worden geweigerd');
select lives_ok($$select app.update_email_template(
  (select id from provider_template_ids where template_key='payment_reminder'),
  'Herinnering voor {{volledige_naam}}', 'Er staat nog {{bedrag}} open. Betaal via {{betaallink}}.', 1)$$,
  'allowlisted plaintext-template wordt optimistic bijgewerkt');
select throws_ok($$select app.update_email_template(
  (select id from provider_template_ids where template_key='payment_reminder'),
  'Tweede wijziging', 'Deze versie is veilig maar de verwachting is verouderd.', 1)$$,
  '40001', 'EMAIL_TEMPLATE_VERSION_CONFLICT', 'verouderde templateversie conflicteert');

reset role;
select is((select version from app.email_templates where template_key='payment_reminder'), 2, 'templateversie is exact één opgehoogd');
select is((select metadata->>'version_after' from app.audit_logs where action='email.template.updated' order by id desc limit 1), '2',
  'templateaudit bevat de nieuwe versie');
select ok((select metadata::text not like '%Er staat nog%' from app.audit_logs where action='email.template.updated' order by id desc limit 1),
  'templateaudit bevat niet de volledige body');

select throws_ok($$select public.prepare_mollie_payment(repeat('9',64), 'b4000000-0000-4000-8000-000000000001', 'provider-attempt-one')$$,
  '42501', 'PARENT_ORDER_ACCESS_DENIED', 'ongeldige oudersessie krijgt geen bestelling');
create temporary table prepared_payment as
select public.prepare_mollie_payment(repeat('1',64), 'b4000000-0000-4000-8000-000000000001', 'provider-attempt-one') result;
select is((result->>'amountCents')::integer, 7500, 'prepare leest het exacte serverbedrag') from prepared_payment;
select is(result->>'currency', 'EUR', 'prepare zet valuta exact op EUR') from prepared_payment;
select is((public.prepare_mollie_payment(repeat('1',64), 'b4000000-0000-4000-8000-000000000001', 'provider-attempt-two')->>'paymentId')::uuid,
  (select (result->>'paymentId')::uuid from prepared_payment), 'open poging wordt hergebruikt');
select is((select count(*) from app.payments where order_id='b4000000-0000-4000-8000-000000000001'), 1::bigint,
  'prepare maakt geen dubbele open poging');

select lives_ok($$select app.bind_mollie_payment(
  (select (result->>'paymentId')::uuid from prepared_payment), 'tr_provider_primary',
  'https://www.mollie.com/checkout/provider-primary', 'open', timezone('utc', now()) + interval '15 minutes')$$,
  'providerbinding slaat uitsluitend hosted checkout en provider-id op');
insert into app.payments(id, order_id, method, status, amount_cents, idempotency_key)
values('b7000000-0000-4000-8000-000000000002', 'b4000000-0000-4000-8000-000000000001', 'mollie', 'open', 7500, 'provider-attempt-duplicate');
select lives_ok($$select app.bind_mollie_payment('b7000000-0000-4000-8000-000000000002', 'tr_provider_duplicate',
  'https://www.mollie.com/checkout/provider-duplicate', 'pending', timezone('utc', now()) + interval '15 minutes')$$,
  'tweede providerpoging kan vóór definitieve betaling bestaan');
select is(app.get_mollie_reconciliation_context('tr_provider_primary')->>'qrVersion', '0',
  'reconciliatiecontext bevat actuele QR-versie nul');

select is(app.reconcile_mollie_payment(
  'event-amount-mismatch', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7499, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '1 minute', null, timezone('utc', now()), null, 0, repeat('2',64),
  '{"schema_version":1,"email":"must-not-persist@example.invalid"}'::jsonb)->>'status', 'manual_review',
  'bedragmismatch commit als manual review');
select is(app.reconcile_mollie_payment(
  'event-currency-mismatch', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7500, 'USD', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '2 minutes', null, timezone('utc', now()), null, 0, repeat('2',64), '{}'::jsonb)->>'status',
  'manual_review', 'valutamismatch commit als manual review');
select is(app.reconcile_mollie_payment(
  'event-metadata-mismatch', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000002',
  (select active_season_id from app.app_settings where id=true), 7500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '3 minutes', null, timezone('utc', now()), null, 0, repeat('2',64), '{}'::jsonb)->>'status',
  'manual_review', 'membermetadata-mismatch commit als manual review');
select is((select count(*) from private.payment_events where event_type='mismatch' and payment_id=(select (result->>'paymentId')::uuid from prepared_payment)),
  3::bigint, 'alle drie mismatchcategorieën staan redacted in de eventledger');
select ok(not exists(select 1 from private.payment_events where provider_payload_redacted::text like '%must-not-persist%'),
  'arbitraire observatie-PII wordt niet opgeslagen');

create temporary table paid_webhook as select app.reconcile_mollie_payment(
  'event-paid-primary', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '4 minutes', null, timezone('utc', now()), null, 0, repeat('2',64),
  '{"schema_version":1}'::jsonb) result;
select is(result->>'effect', 'paid', 'eerste geldige webhook betaalt de order') from paid_webhook;
select is(app.reconcile_mollie_payment(
  'event-paid-primary', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '4 minutes', null, timezone('utc', now()), null, 0, repeat('2',64), '{}'::jsonb)->>'effect',
  'event_replay', 'tweede identieke webhook is een replay');
select is(app.reconcile_mollie_payment(
  'event-paid-primary', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '4 minutes', null, timezone('utc', now()), null, 0, repeat('2',64), '{}'::jsonb)->>'effect',
  'event_replay', 'derde identieke webhook is eveneens een replay');
select is((select count(*) from private.payment_events where idempotency_key='event-paid-primary'), 1::bigint,
  'webhook x3 heeft één idempotent payment-event');
select is((select count(*) from private.qr_tokens where order_id='b4000000-0000-4000-8000-000000000001' and active), 1::bigint,
  'webhook x3 activeert QR exact één keer');
select is((select count(*) from private.email_jobs where order_id='b4000000-0000-4000-8000-000000000001' and template_key='payment_received'), 1::bigint,
  'webhook x3 enqueuet payment_received exact één keer');

select is(app.reconcile_mollie_payment(
  'event-paid-duplicate', 'tr_provider_duplicate', 'b7000000-0000-4000-8000-000000000002',
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()) + interval '5 minutes', null, timezone('utc', now()), null, 1, repeat('3',64), '{}'::jsonb)->>'status',
  'duplicate_paid', 'tweede betaalde providerpoging wordt duplicate_paid');
select is((select count(*) from private.qr_tokens where order_id='b4000000-0000-4000-8000-000000000001'), 1::bigint,
  'duplicate paid maakt geen tweede QR');
select is((select reconciliation_issue from app.payments where id='b7000000-0000-4000-8000-000000000002'),
  'duplicate paid payment; manual reconciliation required', 'duplicate paid krijgt expliciete manual-reviewreden');

select is(app.reconcile_mollie_payment(
  'event-refund-primary', 'tr_provider_primary', (select (result->>'paymentId')::uuid from prepared_payment),
  'b4000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (select active_season_id from app.app_settings where id=true), 7500, 'EUR', 'refunded',
  timezone('utc', now()), timezone('utc', now()) + interval '6 minutes', null, null, timezone('utc', now()), 1, repeat('4',64), '{}'::jsonb)->>'effect',
  'refunded', 'providerrefund wordt verwerkt');
select is((select count(*) from private.qr_tokens where order_id='b4000000-0000-4000-8000-000000000001' and active), 0::bigint,
  'refund blokkeert de actieve QR direct');
select is((select order_status from app.member_orders where id='b4000000-0000-4000-8000-000000000001'), 'Nog niet betaald',
  'refund ververst de orderstatus');

select lives_ok($$select app.record_manual_payment_with_qr_trusted(
  'b0000000-0000-4000-8000-000000000001', 'b4000000-0000-4000-8000-000000000002',
  'card', 'provider-manual-payment', repeat('5',64))$$,
  'trusted handmatige betaling blijft werken');
select is((select count(*) from private.email_jobs where order_id='b4000000-0000-4000-8000-000000000002' and template_key='payment_received'),
  1::bigint, 'handmatige betaling enqueuet payment_received exact één keer');
select is((select jsonb_array_length(payload->'articles') from private.email_jobs
  where order_id='b4000000-0000-4000-8000-000000000002' and template_key='payment_received'), 1,
  'transactionele e-mailjob bevat hele orderregels');

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select lives_ok($$select app.register_delivery_receipt(current_date, 'Provider leverancier', 'PROVIDER-READY',
  '[{"variant_id":"b3000000-0000-4000-8000-000000000001","quantity":1}]'::jsonb)$$,
  'voorraad voor ready-event wordt ontvangen');
select lives_ok($$select app.reserve_order_lines(
  (select line.id from app.delivery_receipt_lines line join app.delivery_receipts receipt on receipt.id=line.receipt_id
    where receipt.packing_slip_reference='PROVIDER-READY'), array['b5000000-0000-4000-8000-000000000002'::uuid])$$,
  'reserveren enqueuet ready-event');
select lives_ok($$select app.create_email_bulk('ready_for_pickup', array['b4000000-0000-4000-8000-000000000002'::uuid], 'ready-bulk-provider')$$,
  'ready_for_pickup is een toegestane bulktemplate');
select throws_ok($$select app.create_email_bulk('payment_request', array['b4000000-0000-4000-8000-000000000002'::uuid], 'invalid-bulk-provider')$$,
  '22023', 'INVALID_EMAIL_BULK', 'bulk weigert niet-canonieke trigger voor deze actie');
reset role;
select is((select count(*) from private.email_jobs where order_id='b4000000-0000-4000-8000-000000000002' and template_key='ready_for_pickup'),
  2::bigint, 'transactioneel ready-event en expliciete bulkjob zijn afzonderlijk idempotent');

create temporary table bulk_order_ids(order_id uuid primary key);
grant select on bulk_order_ids to authenticated;
with source as (select value from generate_series(1, 2000) value), inserted_members as (
  insert into app.members(id, relation_number, first_name, last_name, email, team)
  select md5('provider-bulk-member-' || value)::uuid, 'PROVIDER-BULK-' || lpad(value::text,4,'0'),
    'Bulk', lpad(value::text,4,'0'), 'bulk-' || value || '@example.invalid', 'BULK'
  from source returning id
), inserted_orders as (
  insert into app.member_orders(id, member_id, season_id, amount_due_cents)
  select md5('provider-bulk-order-' || value)::uuid, md5('provider-bulk-member-' || value)::uuid,
    (select active_season_id from app.app_settings where id=true), 12500 from source returning id
)
insert into bulk_order_ids select id from inserted_orders;
insert into app.order_lines(order_id, article_variant_id, quantity)
select order_id, 'b3000000-0000-4000-8000-000000000001', 1 from bulk_order_ids;

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
create temporary table bulk_first as select app.create_email_bulk('payment_reminder',
  (select array_agg(order_id order by order_id) from bulk_order_ids), 'bulk-2000-contract') result;
create temporary table bulk_second as select app.create_email_bulk('payment_reminder',
  (select array_agg(order_id order by order_id) from bulk_order_ids), 'bulk-2000-contract') result;
select is((select (result->>'jobCount')::integer from bulk_first), 2000, 'canonieke bulkcapaciteit accepteert 2.000 orders');
select is((select result->>'reused' from bulk_second), 'true', 'bulk dubbelklik hergebruikt dezelfde batch');
reset role;
select is((select count(*) from private.email_jobs job join app.email_batches batch on batch.id=job.batch_id
  where batch.batch_key='bulk-2000-contract'), 2000::bigint, 'bulk dubbelklik maakt exact 2.000 unieke jobs');
select is((select selected_count from app.email_batches where batch_key='bulk-2000-contract'), 2000,
  'batchpreviewcontract bewaart selected_count 2.000');

update private.email_jobs set available_at = timezone('utc', now()) + interval '1 day'
where batch_id = (select id from app.email_batches where batch_key='bulk-2000-contract');
update private.email_jobs set available_at = timezone('utc', now()) - interval '1 minute'
where id in (select id from private.email_jobs where batch_id=(select id from app.email_batches where batch_key='bulk-2000-contract') order by id limit 30);
create temporary table claimed_25 as select app.claim_email_jobs('b8000000-0000-4000-8000-000000000001', 100) result;
select is(jsonb_array_length(result->'jobs'), 25, 'claim cap is maximaal 25 ondanks hogere limiet') from claimed_25;
create temporary table claimed_ids as select (item->>'id')::uuid id
from claimed_25 cross join lateral jsonb_array_elements(result->'jobs') item;
select lives_ok($$select app.complete_email_job((select id from claimed_ids order by id limit 1),
  'b8000000-0000-4000-8000-000000000001', 'retry', null, 'tijdelijke providerfout')$$,
  'retry-uitkomst wordt opgeslagen');
select ok((select available_at > timezone('utc', now()) from private.email_jobs where id=(select id from claimed_ids order by id limit 1)),
  'retry krijgt exponentieel latere beschikbaarheid');
select lives_ok($$select app.complete_email_job((select id from claimed_ids order by id offset 1 limit 1),
  'b8000000-0000-4000-8000-000000000001', 'sent', 'sg-provider-message-1', null)$$,
  'sent-uitkomst bewaart provider message-id');

select is(app.record_sendgrid_events(jsonb_build_array(
  jsonb_build_object('email_job_id',(select id from claimed_ids order by id offset 1 limit 1),'event_id','sg-event-delivered-1','provider_message_id','different-sg-message-id','event_type','delivered','occurred_at','2026-07-18T12:00:00Z'),
  jsonb_build_object('email_job_id',(select id from claimed_ids order by id offset 1 limit 1),'event_id','sg-event-delivered-1','provider_message_id','different-sg-message-id','event_type','delivered','occurred_at','2026-07-18T12:00:00Z'),
  jsonb_build_object('email_job_id',(select id from claimed_ids order by id offset 1 limit 1),'event_id','sg-event-open-ignored','provider_message_id','different-sg-message-id','event_type','open','occurred_at','2026-07-18T12:01:00Z')
))->>'recorded', '1', 'SendGrid-eventbatch correleert op job-id, dedupet event-id en negeert open');
select is(app.record_sendgrid_events(jsonb_build_array(
  jsonb_build_object('email_job_id',(select id from claimed_ids order by id offset 1 limit 1),'event_id','sg-event-delivered-1','event_type','delivered','occurred_at','2026-07-18T12:00:00Z')
))->>'recorded', '0', 'herhaalde SendGrid-webhook zonder sg_message_id blijft idempotent');
select is((select count(*) from app.email_events where provider_event_id='sg-event-delivered-1'), 1::bigint,
  'provider event-id staat exact één keer in ledger');
select is((select count(*) from app.email_events where event_type in ('open','click')), 0::bigint,
  'open/click worden nooit operationeel opgeslagen');
select is((select delivery_status from private.email_jobs where provider_message_id='sg-provider-message-1'), 'delivered',
  'deliverystatus van de job volgt het gededupete event');

update private.email_jobs set status='retry', attempts=4, available_at=timezone('utc', now())-interval '1 minute',
  claim_token=null, claimed_at=null where id=(select id from claimed_ids order by id limit 1);
update private.email_jobs set available_at=timezone('utc', now())+interval '1 day'
where id<>(select id from claimed_ids order by id limit 1) and status in ('queued','retry');
select is(jsonb_array_length(app.claim_email_jobs('b8000000-0000-4000-8000-000000000002', 1)->'jobs'), 1,
  'retryjob wordt opnieuw geclaimd');
select is((select attempts from private.email_jobs where id=(select id from claimed_ids order by id limit 1)), 5,
  'claim verhoogt attempts tot maximaal vijf');
select is(app.complete_email_job((select id from claimed_ids order by id limit 1),
  'b8000000-0000-4000-8000-000000000002', 'retry', null, 'blijvende providerfout')->>'status', 'failed',
  'retry na poging vijf eindigt definitief failed');

select ok(not exists(select 1 from app.audit_logs where metadata::text ~ '@example|[0-9a-f]{64}'),
  'provideraudit bevat geen e-mail of QR-hash');
select ok(not exists(select 1 from private.payment_events where provider_payload_redacted::text ~ '@example|[0-9a-f]{64}'),
  'payment-eventledger bevat geen PII of QR-materiaal');

select * from finish();
rollback;
