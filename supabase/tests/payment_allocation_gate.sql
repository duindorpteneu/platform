begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('d0000000-0000-4000-8000-000000000001', 'Betaalbeheerder', 'beheerder'),
  ('d0000000-0000-4000-8000-000000000002', 'Betaalcommissie', 'kledingcommissie');

insert into app.members(id, relation_number, first_name, last_name, email, team) values
  ('d1000000-0000-4000-8000-000000000001', 'PAY-V2-001', 'Kas', 'Een', 'kas-een@example.invalid', 'JO11-1'),
  ('d1000000-0000-4000-8000-000000000002', 'PAY-V2-002', 'Mollie', 'Twee', 'mollie-twee@example.invalid', 'JO12-1'),
  ('d1000000-0000-4000-8000-000000000003', 'PAY-V2-003', 'Legacy', 'Drie', 'legacy-drie@example.invalid', 'JO13-1'),
  ('d1000000-0000-4000-8000-000000000004', 'PAY-V2-004', 'Blok', 'Vier', 'blok-vier@example.invalid', 'JO14-1'),
  ('d1000000-0000-4000-8000-000000000005', 'PAY-V2-005', 'Schema', 'Vijf', 'schema-vijf@example.invalid', 'JO15-1');

insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'd2000000-0000-4000-8000-000000000001'::uuid, 'd1000000-0000-4000-8000-000000000001'::uuid, active_season_id, 12500
from app.app_settings where id = true
union all
select 'd2000000-0000-4000-8000-000000000002'::uuid, 'd1000000-0000-4000-8000-000000000002'::uuid, active_season_id, 7500
from app.app_settings where id = true
union all
select 'd2000000-0000-4000-8000-000000000003'::uuid, 'd1000000-0000-4000-8000-000000000003'::uuid, active_season_id, 8500
from app.app_settings where id = true
union all
select 'd2000000-0000-4000-8000-000000000004'::uuid, 'd1000000-0000-4000-8000-000000000004'::uuid, active_season_id, 9500
from app.app_settings where id = true
union all
select 'd2000000-0000-4000-8000-000000000005'::uuid, 'd1000000-0000-4000-8000-000000000005'::uuid, active_season_id, 10500
from app.app_settings where id = true;

select ok(
  not has_function_privilege(
    'service_role',
    'app.record_manual_payment_with_qr_trusted(uuid,uuid,app.payment_method,text,text)',
    'EXECUTE'
  ),
  'service role kan de legacy kas-plus-QR-functie niet meer uitvoeren'
);
select ok(
  not has_function_privilege(
    'service_role',
    'app.reconcile_mollie_payment(text,text,uuid,uuid,uuid,uuid,uuid,integer,text,app.payment_status,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer,text,text,jsonb)',
    'EXECUTE'
  ),
  'service role kan de legacy Mollie-plus-QR-functie niet meer uitvoeren'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.record_manual_payment_v2(uuid,app.payment_method,integer,text,uuid,uuid)',
    'EXECUTE'
  ),
  'authenticated krijgt alleen de zelfautoriserende kas-v2-RPC'
);
select ok(
  not has_table_privilege('authenticated', 'app.payments', 'INSERT')
  and not has_table_privilege('authenticated', 'app.payments', 'UPDATE')
  and not has_table_privilege('authenticated', 'app.payments', 'DELETE'),
  'authenticated heeft geen directe payment-DML'
);
select ok(
  not exists(
    select 1 from pg_policies
    where schemaname = 'app'
      and tablename = 'payments'
      and cmd = 'ALL'
  ),
  'payments heeft geen brede beheerpolicy meer'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.record_manual_payment_v2(
    'd2000000-0000-4000-8000-000000000001',
    'cash',
    12500,
    'Contant ontvangen',
    'd3000000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder op AAL1 kan geen kasbetaling registreren'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.record_manual_payment_v2(
    'd2000000-0000-4000-8000-000000000001',
    'cash',
    12500,
    'Contant ontvangen',
    'd3000000-0000-4000-8000-000000000002'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan ook op AAL2 geen kasbetaling registreren'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.record_manual_payment_v2(
    'd2000000-0000-4000-8000-000000000001',
    'card',
    12500,
    'Pin volledig ontvangen',
    'd3000000-0000-4000-8000-000000000003'
  )$$,
  '55000',
  'LEGACY_CARD_PAYMENT_DISABLED',
  'legacy pinflag staat default gesloten'
);
select throws_ok(
  $$select app.record_manual_payment_v2(
    'd2000000-0000-4000-8000-000000000001',
    'cash',
    1,
    'Contant ontvangen',
    'd3000000-0000-4000-8000-000000000004'
  )$$,
  '23514',
  'MANUAL_PAYMENT_AMOUNT_MISMATCH',
  'browserbedrag moet exact gelijk zijn aan het snapshotschuldbedrag'
);

create temporary table first_cash_result as
select app.record_manual_payment_v2(
  'd2000000-0000-4000-8000-000000000001',
  'cash',
  12500,
  '  Contant   volledig ontvangen  ',
  'd3000000-0000-4000-8000-000000000005',
  'd4000000-0000-4000-8000-000000000001'
) result;
create temporary table replay_cash_result as
select app.record_manual_payment_v2(
  'd2000000-0000-4000-8000-000000000001',
  'cash',
  12500,
  'Contant volledig ontvangen',
  'd3000000-0000-4000-8000-000000000005',
  'd4000000-0000-4000-8000-000000000099'
) result;
reset role;

select is(
  (select result->>'paymentId' from first_cash_result),
  (select result->>'paymentId' from replay_cash_result),
  'dezelfde request-id retourneert exact dezelfde betaling'
);
select is(
  (select result->>'reused' from replay_cash_result),
  'true',
  'idempotente retry is herkenbaar als hergebruik'
);
select is(
  (select count(*) from app.payments where order_id = 'd2000000-0000-4000-8000-000000000001'),
  1::bigint,
  'kasretry maakt exact één payment'
);
select is(
  (select count(*) from private.manual_payment_requests where order_id = 'd2000000-0000-4000-8000-000000000001'),
  1::bigint,
  'kasretry maakt exact één immutable requestledgerregel'
);
select is(
  (select manual_reason from app.payments where order_id = 'd2000000-0000-4000-8000-000000000001'),
  'Contant volledig ontvangen',
  'businessreden wordt veilig genormaliseerd en bewaard'
);
select is(
  (
    select member_season_id
    from app.payments
    where order_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  (
    select member_season_id
    from app.member_orders
    where id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'betaling bewaart de expliciete lid-seizoensnapshot'
);
select is(
  (
    select package_snapshot_id
    from app.payments
    where order_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  (
    select active_package_snapshot_id
    from app.member_orders
    where id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'betaling bewaart de immutable pakketsnapshot'
);
select is(
  (select count(*) from private.qr_tokens where order_id = 'd2000000-0000-4000-8000-000000000001'),
  0::bigint,
  'kasbetaling maakt vóór harde allocatie geen QR'
);
select is(
  (
    select metadata->>'qr_activated'
    from app.audit_logs
    where action = 'payment.manual.recorded_v2'
      and entity_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'false',
  'kasaudit legt expliciet vast dat geen QR is geactiveerd'
);
select is(
  (
    select count(*)
    from private.email_jobs
    where order_id = 'd2000000-0000-4000-8000-000000000001'
      and template_key = 'payment_received'
  ),
  1::bigint,
  'kasretry enqueuet de ontvangstbevestiging exact één keer'
);
set local role authenticated;
select throws_ok(
  $$select app.record_manual_payment_v2(
    'd2000000-0000-4000-8000-000000000001',
    'cash',
    12500,
    'Andere reden',
    'd3000000-0000-4000-8000-000000000005'
  )$$,
  '23505',
  'MANUAL_PAYMENT_IDEMPOTENCY_CONFLICT',
  'dezelfde request-id met andere inhoud faalt gesloten'
);
reset role;

select throws_ok(
  $$update app.payments
    set manual_reason = 'Gewijzigde reden'
    where order_id = 'd2000000-0000-4000-8000-000000000001'$$,
  '23514',
  'MANUAL_PAYMENT_METADATA_IMMUTABLE',
  'handmatige actor en reden zijn immutable'
);
select throws_ok(
  $$delete from private.manual_payment_requests
    where request_id = 'd3000000-0000-4000-8000-000000000005'$$,
  '23514',
  'MANUAL_PAYMENT_REQUEST_IMMUTABLE',
  'handmatige betaalledger is append-only'
);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  provider_payment_id,
  metadata_schema_version
) values (
  'd5000000-0000-4000-8000-000000000001',
  'd2000000-0000-4000-8000-000000000002',
  'mollie',
  'pending',
  7500,
  'payment-v2-provider-attempt',
  'tr_payment_v2',
  2
);

create temporary table paid_v2_result as
select app.reconcile_mollie_payment_v2(
  'payment-v2-paid-event',
  'tr_payment_v2',
  'd5000000-0000-4000-8000-000000000001',
  'd5000000-0000-4000-8000-000000000001',
  'd2000000-0000-4000-8000-000000000002',
  'd1000000-0000-4000-8000-000000000002',
  (select member_season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000002'),
  (select season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000002'),
  7500,
  'EUR',
  'paid',
  timezone('utc', now()) - interval '1 minute',
  timezone('utc', now()),
  null,
  timezone('utc', now()),
  null,
  null,
  '{"schema_version":2}'::jsonb
) result;

select is(
  (select result->>'effect' from paid_v2_result),
  'paid',
  'geldige v2-providerobservatie betaalt de snapshotsbestelling'
);
select is(
  (select status from app.payments where id = 'd5000000-0000-4000-8000-000000000001'),
  'paid'::app.payment_status,
  'Mollieprojectie staat paid'
);
select is(
  (select count(*) from private.qr_tokens where order_id = 'd2000000-0000-4000-8000-000000000002'),
  0::bigint,
  'Molliebetaling maakt vóór harde allocatie geen QR'
);
select is(
  app.reconcile_mollie_payment_v2(
    'payment-v2-paid-event',
    'tr_payment_v2',
    'd5000000-0000-4000-8000-000000000001',
    'd5000000-0000-4000-8000-000000000001',
    'd2000000-0000-4000-8000-000000000002',
    'd1000000-0000-4000-8000-000000000002',
    (select member_season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000002'),
    (select season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000002'),
    7500,
    'EUR',
    'paid',
    timezone('utc', now()) - interval '1 minute',
    timezone('utc', now()),
    null,
    timezone('utc', now()),
    null,
    null,
    '{"schema_version":2}'::jsonb
  )->>'effect',
  'event_replay',
  'identieke Mollie-eventkey is idempotent'
);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  provider_payment_id,
  metadata_schema_version
) values (
  'd5000000-0000-4000-8000-000000000002',
  'd2000000-0000-4000-8000-000000000003',
  'mollie',
  'pending',
  8500,
  'payment-v1-provider-attempt',
  'tr_payment_v1',
  1
);
select is(
  app.reconcile_mollie_payment_v2(
    'payment-v1-paid-event',
    'tr_payment_v1',
    'd5000000-0000-4000-8000-000000000002',
    'd5000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000003',
    'd1000000-0000-4000-8000-000000000003',
    (select member_season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000003'),
    (select season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000003'),
    8500,
    'EUR',
    'paid',
    timezone('utc', now()) - interval '1 minute',
    timezone('utc', now()),
    null,
    timezone('utc', now()),
    null,
    null,
    '{"schema_version":1}'::jsonb
  )->>'effect',
  'paid',
  'historische v1-providerpoging blijft reconcileerbaar'
);
select is(
  (select count(*) from private.qr_tokens where order_id = 'd2000000-0000-4000-8000-000000000003'),
  0::bigint,
  'ook historische v1-reconciliatie maakt geen QR'
);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  provider_payment_id,
  metadata_schema_version
) values (
  'd5000000-0000-4000-8000-000000000003',
  'd2000000-0000-4000-8000-000000000005',
  'mollie',
  'pending',
  10500,
  'payment-schema-downgrade',
  'tr_payment_schema',
  2
);
select is(
  app.reconcile_mollie_payment_v2(
    'payment-schema-downgrade-event',
    'tr_payment_schema',
    'd5000000-0000-4000-8000-000000000003',
    'd5000000-0000-4000-8000-000000000003',
    'd2000000-0000-4000-8000-000000000005',
    'd1000000-0000-4000-8000-000000000005',
    (select member_season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000005'),
    (select season_id from app.member_orders where id = 'd2000000-0000-4000-8000-000000000005'),
    10500,
    'EUR',
    'paid',
    timezone('utc', now()) - interval '1 minute',
    timezone('utc', now()),
    null,
    timezone('utc', now()),
    null,
    null,
    '{"schema_version":1}'::jsonb
  )->>'issue',
  'MOLLIE_METADATA_SCHEMA_MISMATCH',
  'v2-poging accepteert geen metadata-downgrade naar v1'
);
select is(
  (select status from app.payments where id = 'd5000000-0000-4000-8000-000000000003'),
  'pending'::app.payment_status,
  'metadata-downgrade zet betaling niet paid'
);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  provider_payment_id,
  metadata_schema_version
) values (
  'd5000000-0000-4000-8000-000000000004',
  'd2000000-0000-4000-8000-000000000004',
  'mollie',
  'pending',
  9500,
  'payment-active-mollie-block',
  'tr_payment_block',
  2
);
select set_config(
  'request.jwt.claims',
  '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.record_manual_payment_v2(
    'd2000000-0000-4000-8000-000000000004',
    'cash',
    9500,
    'Contant ontvangen',
    'd3000000-0000-4000-8000-000000000006'
  )$$,
  '23514',
  'MOLLIE_ATTEMPT_ACTIVE',
  'actieve Molliepoging blokkeert kas en voorkomt dubbel betalen'
);
reset role;

select * from finish();
rollback;
