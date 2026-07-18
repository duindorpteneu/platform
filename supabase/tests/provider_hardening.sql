begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values('c0000000-0000-4000-8000-000000000001', 'Hardening commissie', 'kledingcommissie');
insert into app.members(id, relation_number, first_name, last_name, email, team) values
  ('c1000000-0000-4000-8000-000000000001', 'HARD-001', 'Snapshot', 'Lid', 'snapshot@example.invalid', 'JO11-1'),
  ('c1000000-0000-4000-8000-000000000002', 'HARD-002', 'Timeout', 'Lid', 'timeout@example.invalid', 'JO13-1'),
  ('c1000000-0000-4000-8000-000000000003', 'HARD-003', 'Metadata', 'Lid', 'metadata@example.invalid', 'JO15-1');
insert into app.articles(id, name, code, icon_type, sort_order)
values('c2000000-0000-4000-8000-000000000001', 'Hardening shirt', 'HARD-SHIRT', 'shirt', 220);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values('c3000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001', '152', 'HARD-152', 1);
insert into app.article_seasons(article_id, season_id)
select 'c2000000-0000-4000-8000-000000000001', active_season_id from app.app_settings where id=true;
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'c4000000-0000-4000-8000-000000000001'::uuid, 'c1000000-0000-4000-8000-000000000001'::uuid, active_season_id, 12500 from app.app_settings where id=true
union all select 'c4000000-0000-4000-8000-000000000002'::uuid, 'c1000000-0000-4000-8000-000000000002'::uuid, active_season_id, 12500 from app.app_settings where id=true
union all select 'c4000000-0000-4000-8000-000000000003'::uuid, 'c1000000-0000-4000-8000-000000000003'::uuid, active_season_id, 12500 from app.app_settings where id=true;
insert into app.order_lines(order_id, article_variant_id, quantity) values
  ('c4000000-0000-4000-8000-000000000001', 'c3000000-0000-4000-8000-000000000001', 1),
  ('c4000000-0000-4000-8000-000000000002', 'c3000000-0000-4000-8000-000000000001', 1),
  ('c4000000-0000-4000-8000-000000000003', 'c3000000-0000-4000-8000-000000000001', 1);

select ok(not has_function_privilege('service_role',
  'app.reconcile_mollie_payment(text,text,uuid,uuid,uuid,uuid,integer,text,app.payment_status,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer,text,jsonb)', 'EXECUTE'),
  'oude reconcile-wrapper zonder metadata-payment-id is voor service role ingetrokken');
select ok(has_function_privilege('service_role',
  'app.reconcile_mollie_payment(text,text,uuid,uuid,uuid,uuid,uuid,integer,text,app.payment_status,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer,text,text,jsonb)', 'EXECUTE'),
  'workercontract vereist metadata-payment-id en expliciete validation issue');

insert into private.parent_accounts(id, email_normalized)
values('c5000000-0000-4000-8000-000000000001', 'timeout@example.invalid');
insert into private.parent_sessions(parent_account_id, token_hash, expires_at)
values('c5000000-0000-4000-8000-000000000001', repeat('6',64), timezone('utc', now()) + interval '1 hour');
insert into private.parent_member_links(parent_account_id, member_id)
values('c5000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002');
insert into app.payments(id, order_id, method, status, amount_cents, idempotency_key, created_at)
values('c6000000-0000-4000-8000-000000000001', 'c4000000-0000-4000-8000-000000000002',
  'mollie', 'open', 12500, 'unbound-hour-old-attempt', timezone('utc', now()) - interval '61 minutes');
select throws_ok($$select public.prepare_mollie_payment(repeat('6',64),
  'c4000000-0000-4000-8000-000000000002', 'replacement-attempt-blocked')$$,
  '23514', 'PAYMENT_ATTEMPT_REVIEW_REQUIRED',
  'unbound open attempt buiten Mollie-idempotencywindow faalt gesloten voor manual review');
select is((select count(*) from app.payments where order_id='c4000000-0000-4000-8000-000000000002'), 1::bigint,
  'fail-closed prepare maakt geen blinde vervangende poging');

insert into app.payments(id, order_id, method, status, amount_cents, idempotency_key, provider_payment_id)
values('c6000000-0000-4000-8000-000000000002', 'c4000000-0000-4000-8000-000000000003',
  'mollie', 'pending', 12500, 'metadata-provider-attempt', 'tr_metadata_context');
select is(app.reconcile_mollie_payment(
  'metadata-payment-id-mismatch', 'tr_metadata_context', 'c6000000-0000-4000-8000-000000000002',
  'c6000000-0000-4000-8000-000000000001',
  'c4000000-0000-4000-8000-000000000003', 'c1000000-0000-4000-8000-000000000003',
  (select active_season_id from app.app_settings where id=true), 12500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()), null, timezone('utc', now()), null, 0, repeat('7',64), null,
  '{"schema_version":1,"email":"discard@example.invalid"}'::jsonb)->>'issue',
  'MOLLIE_METADATA_PAYMENT_MISMATCH', 'provider metadata payment-id mismatch wordt manual review');
select is(app.reconcile_mollie_payment(
  'metadata-malformed-sentinel', 'tr_metadata_context', 'c6000000-0000-4000-8000-000000000002', null,
  'c4000000-0000-4000-8000-000000000003', 'c1000000-0000-4000-8000-000000000003',
  (select active_season_id from app.app_settings where id=true), 12500, 'EUR', 'paid',
  timezone('utc', now()), timezone('utc', now()), null, timezone('utc', now()), null, 0, repeat('7',64),
  'MOLLIE_METADATA_INVALID', '{}'::jsonb)->>'status',
  'manual_review', 'malformed metadata gebruikt een PII-vrije validatiesentinel');
select is((select count(*) from private.payment_events where payment_id='c6000000-0000-4000-8000-000000000002' and event_type='mismatch'),
  2::bigint, 'payment-id mismatch en malformed metadata staan beide in de ledger');
select ok(not exists(select 1 from private.payment_events where provider_payload_redacted::text like '%discard@example%'),
  'arbitraire malformed-metadata-inhoud wordt niet opgeslagen');

select lives_ok($$select app.record_manual_payment_with_qr_trusted(
  'c0000000-0000-4000-8000-000000000001', 'c4000000-0000-4000-8000-000000000001',
  'cash', 'snapshot-manual-payment', repeat('8',64))$$,
  'enqueue maakt transactionele payment_received-job');
create temporary table snapshot_before as select id, template_version, subject_source_snapshot, body_source_snapshot, payload
from private.email_jobs where order_id='c4000000-0000-4000-8000-000000000001' and template_key='payment_received';
create temporary table hardening_template_id as select id from app.email_templates where template_key='payment_received';
grant select on hardening_template_id to authenticated;
select is((select template_version from snapshot_before), 1, 'job bewaart oorspronkelijke templateversie');

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select lives_ok($$select app.update_email_template(
  (select id from hardening_template_id),
  'Nieuwe betalingsbevestiging {{volledige_naam}}',
  'Nieuwe inhoud voor {{volledige_naam}} met bedrag {{bedrag}}.', 1)$$,
  'template kan na enqueue worden gewijzigd');
reset role;
select is((select template_version from private.email_jobs where id=(select id from snapshot_before)), 1,
  'bestaande job houdt versie één na templatewijziging');
select is((select subject_source_snapshot from private.email_jobs where id=(select id from snapshot_before)),
  (select subject_source_snapshot from snapshot_before), 'bestaande job houdt oorspronkelijke onderwerpbron');
select is((select payload from private.email_jobs where id=(select id from snapshot_before)),
  (select payload from snapshot_before), 'bestaande job houdt oorspronkelijke payload');
select throws_ok($$update private.email_jobs set payload='{}'::jsonb where id=(select id from snapshot_before)$$,
  '23514', 'EMAIL_JOB_SNAPSHOT_IMMUTABLE', 'durable jobpayload is immutable');

update private.email_jobs set available_at=timezone('utc', now())+interval '1 day' where id<>(select id from snapshot_before);
create temporary table snapshot_claim as select app.claim_email_jobs('c7000000-0000-4000-8000-000000000001', 1) result;
select is((result #>> '{jobs,0,templateVersion}')::integer, 1,
  'claim retourneert oorspronkelijke jobtemplateversie') from snapshot_claim;
select is(result #>> '{jobs,0,subjectSource}', (select subject_source_snapshot from snapshot_before),
  'claim rendert uit immutable onderwerp-snapshot') from snapshot_claim;
select isnt(result #>> '{jobs,0,subjectSource}',
  (select subject_source from app.email_templates where template_key='payment_received'),
  'claim joint niet de actuele mutable templatebron') from snapshot_claim;

select throws_ok($$insert into private.email_jobs(kind, recipient_email, template_key, payload)
  values('otp', 'otp@example.invalid', 'verification_code', '{"code":"123456"}'::jsonb)$$,
  '23514', 'DURABLE_ORDER_EMAIL_REQUIRED', 'OTP blijft buiten de duurzame orderqueue');

select * from finish();
rollback;
