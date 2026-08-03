begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('73000000-0000-4000-8000-000000000001', 'QR-beheer', 'beheerder'),
  ('73000000-0000-4000-8000-000000000002', 'QR-commissie', 'kledingcommissie'),
  ('73000000-0000-4000-8000-000000000003', 'QR-uitgifte', 'uitgifte');
insert into private.staff_sessions(
  token_hash,
  auth_user_id,
  expires_at
) values
  (
    encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'),
    '73000000-0000-4000-8000-000000000001',
    timezone('utc', now()) + interval '8 hours'
  ),
  (
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    '73000000-0000-4000-8000-000000000003',
    timezone('utc', now()) + interval '8 hours'
  ),
  (
    encode(extensions.digest(repeat('c', 64), 'sha256'), 'hex'),
    '73000000-0000-4000-8000-000000000002',
    timezone('utc', now()) + interval '8 hours'
  );

insert into app.seasons(id, name, default_amount_cents, status)
values (
  '73100000-0000-4000-8000-000000000001',
  'QR 2026-2027',
  12500,
  'open'
);
update app.app_settings
set active_season_id = '73100000-0000-4000-8000-000000000001',
    pickup_location = 'Free-Kick Sport, De Savornin Lohmanplein 45, 2566 AE Den Haag'
where id = true;

insert into app.articles(id, name, code, sort_order, active) values
  (
    '73200000-0000-4000-8000-000000000001',
    'QR-shirt',
    'QR-SHIRT',
    901,
    true
  ),
  (
    '73200000-0000-4000-8000-000000000002',
    'QR-broek',
    'QR-BROEK',
    902,
    true
  );
insert into app.article_seasons(article_id, season_id) values
  (
    '73200000-0000-4000-8000-000000000001',
    '73100000-0000-4000-8000-000000000001'
  ),
  (
    '73200000-0000-4000-8000-000000000002',
    '73100000-0000-4000-8000-000000000001'
  );
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values
  (
    '73300000-0000-4000-8000-000000000001',
    '73200000-0000-4000-8000-000000000001',
    '152',
    'QR-SHIRT-152',
    1,
    true
  ),
  (
    '73300000-0000-4000-8000-000000000002',
    '73200000-0000-4000-8000-000000000002',
    '152',
    'QR-BROEK-152',
    1,
    true
  );

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  gender
) values (
  '73400000-0000-4000-8000-000000000001',
  'QR-001',
  'Noa',
  'Verborgen',
  'noa-qr@example.invalid',
  'JO13-1',
  'female'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
) values (
  '73500000-0000-4000-8000-000000000001',
  '73400000-0000-4000-8000-000000000001',
  '73100000-0000-4000-8000-000000000001',
  12500
);
insert into app.order_lines(id, order_id, article_variant_id) values
  (
    '73600000-0000-4000-8000-000000000001',
    '73500000-0000-4000-8000-000000000001',
    '73300000-0000-4000-8000-000000000001'
  ),
  (
    '73600000-0000-4000-8000-000000000002',
    '73500000-0000-4000-8000-000000000001',
    '73300000-0000-4000-8000-000000000002'
  );

select set_config('app.package_size_internal', 'on', true);
insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  member_season_id,
  selection_status,
  selection_source,
  confirmed_at
)
select
  '73400000-0000-4000-8000-000000000001',
  '73100000-0000-4000-8000-000000000001',
  variant.article_id,
  variant.id,
  member_season.id,
  'confirmed',
  'staff',
  timezone('utc', now()) - interval '2 days'
from app.article_variants variant
join app.member_seasons member_season
  on member_season.member_id = '73400000-0000-4000-8000-000000000001'
  and member_season.season_id = '73100000-0000-4000-8000-000000000001'
where variant.id in (
  '73300000-0000-4000-8000-000000000001',
  '73300000-0000-4000-8000-000000000002'
)
on conflict (member_id, season_id, article_id) do update
set article_variant_id = excluded.article_variant_id,
    member_season_id = excluded.member_season_id,
    selection_status = excluded.selection_status,
    selection_source = excluded.selection_source,
    raw_value = null,
    member_note = null,
    confirmed_at = excluded.confirmed_at,
    updated_at = timezone('utc', now());
select set_config('app.package_size_internal', 'off', true);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  '73700000-0000-4000-8000-000000000001',
  '73500000-0000-4000-8000-000000000001',
  'cash',
  'paid',
  12500,
  'secure-qr-paid-0001',
  timezone('utc', now()) - interval '1 day'
);
insert into app.inventory_movements(
  season_id,
  article_id,
  article_variant_id,
  movement_type,
  on_hand_delta,
  source_type,
  reason_code,
  idempotency_key
) values (
  '73100000-0000-4000-8000-000000000001',
  '73200000-0000-4000-8000-000000000001',
  '73300000-0000-4000-8000-000000000001',
  'opening_balance',
  1,
  'secure_qr_test',
  'secure_qr.opening_shirt',
  repeat('1', 64)
);

insert into private.release_cutovers(key)
values ('allocation_qr_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key in ('allocation_qr_v2', 'scanner_pwa_v2');
select private.allocate_inventory_fifo_variant(
  '73100000-0000-4000-8000-000000000001',
  '73300000-0000-4000-8000-000000000001',
  'secure_qr_test'
);

select is(
  (
    select status::text
    from app.order_lines
    where id = '73600000-0000-4000-8000-000000000001'
  ),
  'ready_for_pickup',
  'alleen de fysiek beschikbare betaalde regel wordt hard gereserveerd'
);
select is(
  (
    select status::text
    from app.order_lines
    where id = '73600000-0000-4000-8000-000000000002'
  ),
  'backorder',
  'de nog niet geleverde component blijft nalevering'
);

select lives_ok(
  $$select app.register_order_qr_locator(
    '73500000-0000-4000-8000-000000000001',
    1,
    1,
    repeat('n', 43),
    repeat('9', 64),
    repeat('d', 64),
    '73800000-0000-4000-8000-000000000001'
  )$$,
  'de server provisiont één gehashte locatoridentiteit'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"73000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.get_member_detail_v3(
    '73400000-0000-4000-8000-000000000001'
  ) #>> '{order,qrStatus}',
  'Actief',
  'het beheer-liddetail gebruikt na cutover de actieve locatorstatus'
);
select is(
  app.get_operational_health_v6(
    repeat('9', 64),
    1,
    null,
    null
  ) #>> '{qrControl,keyMismatchActiveLocators}',
  '0',
  'health accepteert de actieve huidige QR-sleutel'
);
select is(
  app.get_operational_health_v6(
    repeat('8', 64),
    2,
    repeat('9', 64),
    1
  ) #>> '{qrControl,keyMismatchActiveLocators}',
  '0',
  'health accepteert tijdens rotatie ook exact de vorige QR-sleutel'
);
select is(
  app.get_operational_health_v6(
    repeat('8', 64),
    2,
    null,
    null
  ) #>> '{qrControl,keyMismatchActiveLocators}',
  '1',
  'health blokkeert het te vroeg verwijderen van de vorige QR-sleutel'
);
select set_config('app.qr_internal', 'on', true);
select throws_ok(
  $$update private.qr_order_locators
    set derivation_nonce = repeat('x', 43)
    where order_id = '73500000-0000-4000-8000-000000000001'$$,
  '23514',
  'QR_LOCATOR_IDENTITY_IMMUTABLE',
  'de random derivation nonce kan na provisioning niet worden gewijzigd'
);
select set_config('app.qr_internal', 'off', true);
select is(
  app.exchange_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('0', 64),
    repeat('e', 64),
    1,
    '73800000-0000-4000-8000-000000000002'
  )->>'status',
  'invalid',
  'een onbekende locator geeft uniform ongeldig zonder PII'
);
select throws_ok(
  $$select app.exchange_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000002',
    encode(extensions.digest(repeat('c', 64), 'sha256'), 'hex'),
    repeat('d', 64),
    repeat('e', 64),
    1,
    '73800000-0000-4000-8000-000000000003'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan de uitgiftescanner niet gebruiken'
);

create temporary table first_exchange as
select app.exchange_order_qr_locator_v2(
  '73000000-0000-4000-8000-000000000003',
  encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
  repeat('d', 64),
  repeat('e', 64),
  1,
  '73800000-0000-4000-8000-000000000004'
) result;
select is(
  (select result #>> '{member,firstName}' from first_exchange),
  'Noa',
  'scanner ziet uitsluitend de voornaam'
);
select is(
  (select result #>> '{member,gender}' from first_exchange),
  'female',
  'scanner ziet het geregistreerde geslacht'
);
select ok(
  (
    select
      position('Verborgen' in result::text) = 0
      and position('noa-qr' in result::text) = 0
      and position('JO13-1' in result::text) = 0
      and position('dateOfBirth' in result::text) = 0
      and position('relationNumber' in result::text) = 0
      and position('orderId' in result::text) = 0
    from first_exchange
  ),
  'scannerresponse bevat geen achternaam, e-mail, team, DOB, relatie- of ordernummer'
);
select cmp_ok(
  (
    select (result->>'grantExpiresAt')::timestamptz
      - timezone('utc', now())
    from first_exchange
  ),
  '<=',
  interval '2 minutes 1 second',
  'de scanbevoegdheid is hoogstens twee minuten geldig'
);

create temporary table first_commit as
select app.commit_fulfilment_v3(
  '73000000-0000-4000-8000-000000000003',
  encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
  repeat('e', 64),
  array['73600000-0000-4000-8000-000000000001'::uuid],
  '73800000-0000-4000-8000-000000000005',
  null
) result;
select is(
  (select result->>'outcome' from first_commit),
  'partial_pickup',
  'eerste uitgifte veroorzaakt uitsluitend een deeluitgifte'
);
select is(
  (
    select status::text
    from app.inventory_allocations
    where order_line_id = '73600000-0000-4000-8000-000000000001'
  ),
  'fulfilled',
  'deeluitgifte voltooit de concrete harde allocatie'
);
select results_eq(
  $$select on_hand_delta, reserved_delta, issued_delta
    from app.inventory_movements
    where movement_type = 'fulfilment_issued'
      and allocation_id = (
        select id from app.inventory_allocations
        where order_line_id = '73600000-0000-4000-8000-000000000001'
      )$$,
  $$values (-1, -1, 1)$$,
  'uitgifte schrijft exact de journalvector -fysiek, -gereserveerd, +uitgegeven'
);
select is(
  (
    select count(*)::integer
    from private.fulfilment_notification_events
    where event_type = 'partial_pickup'
  ),
  1,
  'deeluitgifte schrijft exact één immutable notificatie-event'
);
select is(
  app.commit_fulfilment_v3(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('e', 64),
    array['73600000-0000-4000-8000-000000000001'::uuid],
    '73800000-0000-4000-8000-000000000005',
    null
  )->>'reused',
  'true',
  'identieke commitretry retourneert de opgeslagen uitkomst'
);
select throws_ok(
  $$select app.commit_fulfilment_v3(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('e', 64),
    array['73600000-0000-4000-8000-000000000002'::uuid],
    '73800000-0000-4000-8000-000000000005',
    null
  )$$,
  '23505',
  'FULFILMENT_IDEMPOTENCY_CONFLICT',
  'dezelfde request-ID met andere inhoud wordt geblokkeerd'
);
select is(
  app.commit_fulfilment_v3(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('e', 64),
    array['73600000-0000-4000-8000-000000000001'::uuid],
    '73800000-0000-4000-8000-000000000006',
    null
  )->>'status',
  'stale',
  'een verbruikte scanbevoegdheid kan geen tweede mutatie uitvoeren'
);

insert into app.inventory_movements(
  season_id,
  article_id,
  article_variant_id,
  movement_type,
  on_hand_delta,
  source_type,
  reason_code,
  idempotency_key
) values (
  '73100000-0000-4000-8000-000000000001',
  '73200000-0000-4000-8000-000000000002',
  '73300000-0000-4000-8000-000000000002',
  'receipt',
  1,
  'secure_qr_test',
  'secure_qr.receipt_trousers',
  repeat('2', 64)
);
select private.allocate_inventory_fifo_variant(
  '73100000-0000-4000-8000-000000000001',
  '73300000-0000-4000-8000-000000000002',
  'secure_qr_test'
);
select is(
  (
    select count(*)::integer
    from private.qr_order_locators locator
    join private.qr_order_identities identity
      on identity.id = locator.identity_id
    where identity.order_id = '73500000-0000-4000-8000-000000000001'
      and locator.active
      and locator.generation = 1
  ),
  1,
  'dezelfde QR-identiteit blijft voor de nalevering actief'
);

create temporary table second_exchange as
select app.exchange_order_qr_locator_v2(
  '73000000-0000-4000-8000-000000000003',
  encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
  repeat('d', 64),
  repeat('f', 64),
  1,
  '73800000-0000-4000-8000-000000000007'
) result;
select is(
  (select result->>'status' from second_exchange),
  'found',
  'dezelfde locator levert na nieuwe reservering een nieuwe korte grant'
);
create temporary table second_commit as
select app.commit_fulfilment_v3(
  '73000000-0000-4000-8000-000000000003',
  encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
  repeat('f', 64),
  array['73600000-0000-4000-8000-000000000002'::uuid],
  '73800000-0000-4000-8000-000000000008',
  null
) result;
select is(
  (select result->>'outcome' from second_commit),
  'package_complete',
  'de laatste nalevering geeft uitsluitend de eindbevestiging'
);
select is(
  (
    select count(*)::integer
    from private.fulfilment_notification_events
    where event_type = 'package_complete'
  ),
  1,
  'de volledige bestelling heeft exact één eindevent'
);
select is(
  (
    select count(*)::integer
    from private.fulfilment_notification_events
  ),
  2,
  'partial en final zijn exclusief per uitgiftemoment'
);

select throws_ok(
  $$select app.correct_fulfilment_v3(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    array['73600000-0000-4000-8000-000000000001'::uuid],
    'ready_for_pickup',
    'Onjuiste tas meegegeven',
    '73800000-0000-4000-8000-000000000009',
    null
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifterol kan een uitgifte niet corrigeren'
);
select is(
  app.correct_fulfilment_v3(
    '73000000-0000-4000-8000-000000000001',
    encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'),
    array['73600000-0000-4000-8000-000000000001'::uuid],
    'ready_for_pickup',
    'Onjuiste tas meegegeven',
    '73800000-0000-4000-8000-000000000010',
    null
  )->>'status',
  'corrected',
  'beheerder herstelt uitgifte journalgedreven naar afhaalklaar'
);
select results_eq(
  $$select on_hand_delta, reserved_delta, issued_delta
    from app.inventory_movements
    where movement_type = 'fulfilment_reversed_ready'
      and allocation_id = (
        select id from app.inventory_allocations
        where order_line_id = '73600000-0000-4000-8000-000000000001'
      )$$,
  $$values (1, 1, -1)$$,
  'correctie schrijft exact de inverse journalvector'
);

select is(
  app.exchange_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('d', 64),
    repeat('7', 64),
    1,
    '73800000-0000-4000-8000-000000000011'
  )->>'status',
  'found',
  'na herstel is dezelfde QR opnieuw bruikbaar'
);
insert into private.qr_scan_grants(
  locator_id,
  order_id,
  actor_user_id,
  staff_session_hash,
  exchange_request_id,
  exchange_request_hash,
  key_version,
  grant_hash,
  created_at,
  expires_at
)
select
  locator.id,
  locator.order_id,
  '73000000-0000-4000-8000-000000000003',
  encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
  '73800000-0000-4000-8000-000000000012',
  repeat('6', 64),
  1,
  repeat('5', 64),
  timezone('utc', now()) - interval '2 minutes',
  timezone('utc', now()) - interval '1 second'
from private.qr_order_locators locator
where locator.order_id = '73500000-0000-4000-8000-000000000001'
  and locator.active;
select is(
  (app.expire_qr_scan_grants(10)->>'expired')::integer,
  1,
  'de worker trekt een verlopen open scangrant begrensd in'
);
select is(
  (app.expire_qr_scan_grants(10)->>'expired')::integer,
  0,
  'grant-expiry is idempotent'
);
select ok(
  exists(
    select 1
    from private.qr_scan_grants
    where grant_hash = repeat('5', 64)
      and revoked_at is not null
      and revocation_reason = 'Scanbevoegdheid is verlopen'
  ),
  'een verlopen grant bewaart een expliciete intrekkingsreden'
);
insert into app.audit_logs(
  actor_user_id,
  action,
  entity_type,
  metadata
)
select
  '73000000-0000-4000-8000-000000000003',
  'qr.exchange.rejected',
  'member_order',
  jsonb_build_object('reason', 'rate_limit_test')
from generate_series(1, 60);
select is(
  app.exchange_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('d', 64),
    repeat('7', 64),
    1,
    '73800000-0000-4000-8000-000000000011'
  )->>'status',
  'found',
  'een identieke exchange-retry blijft ook onder rate limiting bruikbaar'
);
select throws_ok(
  $$select app.exchange_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000003',
    encode(extensions.digest(repeat('b', 64), 'sha256'), 'hex'),
    repeat('d', 64),
    repeat('8', 64),
    1,
    '73800000-0000-4000-8000-000000000013'
  )$$,
  'P0001',
  'QR_EXCHANGE_RATE_LIMITED',
  'een nieuwe scanpoging wordt na de limiet uniform geblokkeerd'
);
select is(
  app.revoke_staff_app_session(repeat('b', 64)),
  1,
  'logout trekt de actieve medewerkerssessie in'
);
select ok(
  exists(
    select 1
    from private.qr_scan_grants
    where grant_hash = repeat('7', 64)
      and revoked_at is not null
  ),
  'logout trekt alle open sessiegebonden scangrants direct in'
);

select is(
  app.manage_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000001',
    encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'),
    '73500000-0000-4000-8000-000000000001',
    'rotate',
    1,
    2,
    repeat('x', 43),
    repeat('8', 64),
    repeat('4', 64),
    'Gecontroleerde sleutelrotatie',
    '73800000-0000-4000-8000-000000000014',
    null
  )->>'generation',
  '2',
  'beheer roteert de actieve locator naar een nieuwe generatie en sleutel'
);
select is(
  app.manage_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000001',
    encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'),
    '73500000-0000-4000-8000-000000000001',
    'rotate',
    2,
    3,
    repeat('y', 43),
    repeat('7', 64),
    repeat('3', 64),
    'Gecontroleerde sleutelrotatie',
    '73800000-0000-4000-8000-000000000014',
    null
  )->>'reused',
  'true',
  'een retry na verloren rotatieresponse hergebruikt de eerste uitkomst'
);
select is(
  (
    select count(*)::integer
    from private.qr_order_locators
    where order_id = '73500000-0000-4000-8000-000000000001'
      and active
      and generation = 2
      and key_version = 2
  ),
  1,
  'een verloren response maakt geen tweede locatorgeneratie'
);
select is(
  app.exchange_order_qr_locator_v2(
    '73000000-0000-4000-8000-000000000001',
    encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'),
    repeat('d', 64),
    repeat('2', 64),
    2,
    '73800000-0000-4000-8000-000000000015'
  )->>'status',
  'invalid',
  'de oude locator is na rotatie uniform ongeldig'
);
select is(
  app.get_operational_health_v6(
    repeat('8', 64),
    2,
    repeat('9', 64),
    1
  ) #>> '{qrControl,previousKeyActiveLocators}',
  '0',
  'de previous-key locatorgate is nul na gecontroleerde rotatie'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'private.qr_scan_grants',
    'SELECT'
  )
  and not has_table_privilege(
    'service_role',
    'private.qr_scan_grants',
    'SELECT'
  ),
  'QR-locators en grants zijn uitsluitend via smalle RPCs bereikbaar'
);
select throws_ok(
  $$update private.fulfilment_notification_events
    set event_type = 'package_complete'
    where event_type = 'partial_pickup'$$,
  '23514',
  'QR_EVENT_IMMUTABLE',
  'notificatiehistorie is onveranderlijk'
);
select ok(
  not exists(
    select 1
    from app.audit_logs
    where metadata::text like '%' || repeat('d', 64) || '%'
      or metadata::text like '%' || repeat('e', 64) || '%'
      or metadata::text like '%' || repeat('f', 64) || '%'
  ),
  'auditlogs bevatten geen locator- of granthashes'
);

select * from finish();
rollback;
