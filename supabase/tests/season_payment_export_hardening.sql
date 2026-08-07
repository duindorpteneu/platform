begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values
  (
    'f7000000-0000-4000-8000-000000000001',
    'Refund beheerder',
    'beheerder'
  ),
  (
    'f7000000-0000-4000-8000-000000000002',
    'Refund commissie',
    'kledingcommissie'
  );

insert into app.seasons(
  id,
  name,
  starts_on,
  ends_on,
  default_amount_cents,
  status,
  opened_at
) values (
  'f7100000-0000-4000-8000-000000000001',
  'Refundseizoen',
  '2026-07-01',
  '2027-06-30',
  12500,
  'open',
  timezone('utc', now())
);
update app.app_settings
set active_season_id = 'f7100000-0000-4000-8000-000000000001'
where id = true;

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  active_for_season
) values (
  'f7200000-0000-4000-8000-000000000001',
  'REF-001',
  'Refund',
  'Voorbeeld',
  'refund@example.invalid',
  'JO15-1',
  true
);
insert into app.articles(id, name, code, sort_order)
values (
  'f7300000-0000-4000-8000-000000000001',
  'Refund shirt',
  'REF-SHIRT',
  901
);
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order
) values (
  'f7400000-0000-4000-8000-000000000001',
  'f7300000-0000-4000-8000-000000000001',
  'M',
  'REF-M',
  1
);
insert into app.article_seasons(article_id, season_id)
values (
  'f7300000-0000-4000-8000-000000000001',
  'f7100000-0000-4000-8000-000000000001'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents,
  order_status
) values (
  'f7500000-0000-4000-8000-000000000001',
  'f7200000-0000-4000-8000-000000000001',
  'f7100000-0000-4000-8000-000000000001',
  12500,
  'Nog niet betaald'
);
insert into app.order_lines(
  id,
  order_id,
  article_variant_id,
  quantity,
  status
) values (
  'f7600000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000001',
  'f7400000-0000-4000-8000-000000000001',
  1,
  'backorder'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"f7000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select app.record_manual_payment_refund_v1(
    'f7500000-0000-4000-8000-000000000001',
    'f7700000-0000-4000-8000-000000000001',
    12500,
    'Extern terugbetaald',
    'Kasbon REF-001',
    'f7800000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan geen handmatige refund vastleggen'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"f7000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table refund_payment as
select app.record_manual_payment_v2(
  'f7500000-0000-4000-8000-000000000001',
  'cash',
  12500,
  'Contant ontvangen voor test',
  'f7900000-0000-4000-8000-000000000001'
) result;
grant select on refund_payment to authenticated;

select is(
  (select result->>'status' from refund_payment),
  'paid',
  'AAL2-beheerder registreert de exacte kasbetaling'
);
reset role;
select ok(
  private.order_has_effective_paid_payment(
    'f7500000-0000-4000-8000-000000000001'
  ),
  'exact gereconcilieerde betaling projecteert als betaald'
);
select ok(
  position(
    'active_for_season' in pg_get_functiondef(
      'private.member_size_revision_v2(uuid)'::regprocedure
    )
  ) = 0,
  'de maat-revisie bevat geen globale legacy seizoensvlag'
);

insert into private.qr_order_identities(
  id,
  order_id,
  member_season_id,
  season_id,
  last_generation
)
select
  'f7a00000-0000-4000-8000-000000000001',
  orders.id,
  orders.member_season_id,
  orders.season_id,
  1
from app.member_orders orders
where orders.id = 'f7500000-0000-4000-8000-000000000001';
insert into private.qr_order_locators(
  id,
  identity_id,
  order_id,
  generation,
  key_version,
  derivation_nonce,
  pepper_fingerprint,
  locator_hash,
  created_by
) values (
  'f7b00000-0000-4000-8000-000000000001',
  'f7a00000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000001',
  1,
  1,
  repeat('A', 43),
  repeat('a', 64),
  repeat('b', 64),
  'f7000000-0000-4000-8000-000000000001'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"f7000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  app.get_member_detail_v3(
    'f7200000-0000-4000-8000-000000000001'
  )#>>'{order,qrStatus}',
  'Ingetrokken',
  'een locator zonder afhaalklare allocatie is niet actief'
);
reset role;

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  currency,
  idempotency_key,
  reconciliation_issue
) values (
  'f7700000-0000-4000-8000-000000000002',
  'f7500000-0000-4000-8000-000000000001',
  'mollie',
  'duplicate_paid',
  12500,
  'EUR',
  'refund-conflict-fixture',
  'duplicate paid payment; manual reconciliation required'
);
select ok(
  not private.order_has_effective_paid_payment(
    'f7500000-0000-4000-8000-000000000001'
  ),
  'een duplicate-paid-conflict maakt de primaire betaling fail-closed'
);
select is(
  private.export_effective_payment_status(
    'f7500000-0000-4000-8000-000000000001'
  ),
  'reconciliation_required',
  'een betaalconflict heeft een afzonderlijke reviewprojectie'
);
select is(
  private.order_effective_payment_status(
    'f7500000-0000-4000-8000-000000000001'
  ),
  'open',
  'het oudercontract blijft fail-closed compatibel'
);
select is(
  (
    select count(*)
    from private.qr_order_locators
    where order_id = 'f7500000-0000-4000-8000-000000000001'
      and active
  ),
  0::bigint,
  'het betaalconflict trekt de actieve QR-locator direct in'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"f7000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  (
    app.get_member_list(p_payment_filter => 'review')
      ->>'filteredCount'
  )::integer,
  1,
  'het reviewfilter toont precies het conflict'
);
select is(
  (
    app.get_member_list(p_payment_filter => 'unpaid')
      ->>'filteredCount'
  )::integer,
  0,
  'het onbetaaldfilter sluit reviewgevallen uit'
);
select is(
  app.get_member_detail_v3(
    'f7200000-0000-4000-8000-000000000001'
  )#>>'{order,paymentStatus}',
  'Controle vereist',
  'detail presenteert een conflict niet als onbetaald'
);
select throws_ok(
  $$select app.record_manual_payment_refund_v1(
    'f7500000-0000-4000-8000-000000000001',
    (select (result->>'paymentId')::uuid from refund_payment),
    12500,
    'Contante betaling teruggegeven',
    'Kasbon REF-001',
    'f7800000-0000-4000-8000-000000000001'
  )$$,
  '23514',
  'PAYMENT_RECONCILIATION_OPEN',
  'een open betaalconflict blokkeert de refundcorrectie'
);

reset role;
delete from app.payments
where id = 'f7700000-0000-4000-8000-000000000002';

select set_config(
  'request.jwt.claims',
  '{"sub":"f7000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.record_manual_payment_refund_v1(
    'f7500000-0000-4000-8000-000000000001',
    (select (result->>'paymentId')::uuid from refund_payment),
    12500,
    'Contante betaling teruggegeven',
    'Kasbon REF-001',
    'f7800000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan geen refundcorrectie vastleggen'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"f7000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table refund_result as
select app.record_manual_payment_refund_v1(
  'f7500000-0000-4000-8000-000000000001',
  (select (result->>'paymentId')::uuid from refund_payment),
  12500,
  'Contante betaling teruggegeven',
  'Kasbon REF-001',
  'f7800000-0000-4000-8000-000000000001'
) result;
grant select on refund_result to authenticated;

select is(
  (select result->>'status' from refund_result),
  'refunded',
  'de externe kasrefund wordt expliciet vastgelegd'
);
select is(
  (select result->>'refundCreated' from refund_result),
  'false',
  'de registratie claimt nooit zelf een refund te hebben uitgevoerd'
);
select is(
  (select result->>'qrRevoked' from refund_result),
  'false',
  'de refund claimt geen tweede intrekking na eerdere conflictrevocation'
);
select is(
  (
    app.record_manual_payment_refund_v1(
      'f7500000-0000-4000-8000-000000000001',
      (select (result->>'paymentId')::uuid from refund_payment),
      12500,
      'Contante betaling teruggegeven',
      'Kasbon REF-001',
      'f7800000-0000-4000-8000-000000000001'
    )->>'reused'
  )::boolean,
  true,
  'een identieke retry hergebruikt het immutable resultaat'
);

reset role;
select is(
  (
    select count(*)
    from private.manual_payment_corrections
    where request_id = 'f7800000-0000-4000-8000-000000000001'
      and member_season_id is not null
      and package_snapshot_id is not null
      and evidence_reference = 'Kasbon REF-001'
  ),
  1::bigint,
  'de private ledger bewaart seizoen, snapshot en bewijsreferentie exact eenmaal'
);
select is(
  (
    select count(*)
    from private.qr_order_locators
    where order_id = 'f7500000-0000-4000-8000-000000000001'
      and active
  ),
  0::bigint,
  'na refund resteert geen actieve QR-locator'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'payment.manual.refund_recorded'
      and entity_id = (
        select (result->>'paymentId')::uuid from refund_payment
      )
      and metadata->>'evidence_recorded' = 'true'
      and metadata ? 'evidence_sha256'
  ),
  1::bigint,
  'de refundcorrectie is zonder ruwe bewijsinhoud geaudit'
);
select throws_ok(
  $$update private.manual_payment_corrections
    set evidence_reference = 'Gewijzigd bewijs'
    where request_id = 'f7800000-0000-4000-8000-000000000001'$$,
  '23514',
  'MANUAL_PAYMENT_CORRECTION_IMMUTABLE',
  'de refundledger is immutable'
);

select * from finish();
rollback;
