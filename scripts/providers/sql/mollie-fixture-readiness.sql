begin;

do $lock$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('duindorp:mollie-acceptance-fixture', 0)
  );
end
$lock$;

create temporary table mollie_acceptance_input (
  paid_member_id uuid not null,
  mismatch_member_id uuid not null,
  paid_order_id uuid not null,
  mismatch_order_id uuid not null,
  readiness_article_id uuid not null,
  readiness_variant_id uuid not null,
  readiness_order_line_id uuid not null,
  readiness_qr_request_id uuid not null,
  paid_relation text not null,
  mismatch_relation text not null,
  fixture_email text not null
) on commit drop;

insert into mollie_acceptance_input values (
  :'paid_member_id'::uuid,
  :'mismatch_member_id'::uuid,
  :'paid_order_id'::uuid,
  :'mismatch_order_id'::uuid,
  :'readiness_article_id'::uuid,
  :'readiness_variant_id'::uuid,
  :'readiness_order_line_id'::uuid,
  :'readiness_qr_request_id'::uuid,
  :'paid_relation',
  :'mismatch_relation',
  :'fixture_email'
);

create temporary table mollie_acceptance_readiness_result (
  value jsonb not null
) on commit drop;

do $fixture$
declare
  fixture_input mollie_acceptance_input%rowtype;
  fixture_season_id uuid;
  allocation_result jsonb;
  provision_result jsonb;
  derivation_nonce text;
  pepper_fingerprint text;
  locator_hash text;
  result jsonb;
begin
  select * into strict fixture_input from mollie_acceptance_input;

  if fixture_input.paid_relation !~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-P$'
    or fixture_input.mismatch_relation !~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-M$'
    or fixture_input.fixture_email
      !~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$'
    or regexp_replace(fixture_input.paid_relation, '^MOLLIE-(.+)-P$', '\1')
      <> regexp_replace(fixture_input.mismatch_relation, '^MOLLIE-(.+)-M$', '\1')
    or regexp_replace(fixture_input.paid_relation, '^MOLLIE-(.+)-P$', '\1')
      <> regexp_replace(
        fixture_input.fixture_email,
        '^mollie-acceptance\+(.+)@example\.invalid$',
        '\1'
      )
  then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY'
      using errcode = '22023';
  end if;

  select orders.season_id into strict fixture_season_id
  from app.member_orders orders
  join app.members member
    on member.id = orders.member_id
   and member.id = fixture_input.paid_member_id
   and member.relation_number = fixture_input.paid_relation
   and member.email = fixture_input.fixture_email
   and member.team = 'MOLLIE-ACCEPTANCE'
  join app.order_lines line
    on line.id = fixture_input.readiness_order_line_id
   and line.order_id = orders.id
   and line.article_id = fixture_input.readiness_article_id
   and line.article_variant_id = fixture_input.readiness_variant_id
   and line.quantity = 1
   and line.status = 'backorder'
  join app.member_article_sizes size_choice
    on size_choice.member_id = orders.member_id
   and size_choice.season_id = orders.season_id
   and size_choice.member_season_id = orders.member_season_id
   and size_choice.article_id = fixture_input.readiness_article_id
   and size_choice.article_variant_id = fixture_input.readiness_variant_id
   and size_choice.selection_status = 'confirmed'
   and size_choice.confirmed_at is not null
  join app.payments payment
    on payment.order_id = orders.id
   and payment.status = 'paid'
   and payment.reconciliation_issue is null
   and payment.amount_cents = orders.amount_due_cents
   and payment.currency = 'EUR'
   and payment.member_season_id = orders.member_season_id
   and payment.package_snapshot_id = orders.active_package_snapshot_id
  where orders.id = fixture_input.paid_order_id
    and orders.amount_due_cents = 100;

  if exists (
    select 1
    from app.inventory_allocations allocation
    where allocation.order_id = fixture_input.paid_order_id
  ) or exists (
    select 1
    from app.inventory_movements movement
    where movement.season_id = fixture_season_id
      and movement.article_variant_id = fixture_input.readiness_variant_id
  ) or exists (
    select 1
    from private.qr_tokens token
    where token.order_id = fixture_input.paid_order_id
  ) or exists (
    select 1
    from private.qr_order_identities identity
    where identity.order_id = fixture_input.paid_order_id
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_READINESS_NOT_CLEAN'
      using errcode = '23514';
  end if;

  insert into app.inventory_movements(
    season_id,
    article_id,
    article_variant_id,
    movement_type,
    on_hand_delta,
    source_type,
    source_id,
    reason_code,
    idempotency_key,
    safe_context
  ) values (
    fixture_season_id,
    fixture_input.readiness_article_id,
    fixture_input.readiness_variant_id,
    'opening_balance',
    1,
    'mollie_acceptance',
    fixture_input.paid_order_id,
    'mollie_acceptance.temporary_opening',
    encode(
      extensions.digest(
        'mollie-acceptance-opening:' || fixture_input.paid_order_id::text,
        'sha256'
      ),
      'hex'
    ),
    jsonb_build_object('variantId', fixture_input.readiness_variant_id)
  );

  allocation_result := private.allocate_inventory_fifo_variant(
    fixture_season_id,
    fixture_input.readiness_variant_id,
    'mollie_acceptance',
    fixture_input.paid_order_id,
    null,
    null
  );
  if coalesce((allocation_result->>'allocatedLines')::integer, 0) <> 1
    or coalesce((allocation_result->>'allocatedQuantity')::integer, 0) <> 1
    or coalesce((allocation_result->>'blockedByConcurrentMutation')::boolean, true)
  then
    raise exception 'MOLLIE_ACCEPTANCE_HARD_ALLOCATION_FAILED'
      using errcode = '23514';
  end if;

  derivation_nonce := translate(
    rtrim(
      encode(
        extensions.digest(
          'mollie-acceptance-nonce:'
            || fixture_input.readiness_qr_request_id::text,
          'sha256'
        ),
        'base64'
      ),
      '='
    ),
    '+/',
    '-_'
  );
  pepper_fingerprint := encode(
    extensions.digest(
      'mollie-acceptance-pepper:'
        || fixture_input.readiness_qr_request_id::text,
      'sha256'
    ),
    'hex'
  );
  locator_hash := encode(
    extensions.digest(
      'mollie-acceptance-locator:'
        || fixture_input.readiness_qr_request_id::text,
      'sha256'
    ),
    'hex'
  );
  provision_result := app.register_order_qr_locator(
    fixture_input.paid_order_id,
    1,
    1,
    derivation_nonce,
    pepper_fingerprint,
    locator_hash,
    fixture_input.readiness_qr_request_id
  );

  select jsonb_build_object(
    'paymentStatus', payment.status::text,
    'allocatedLines', allocation_result->'allocatedLines',
    'allocatedQuantity', allocation_result->'allocatedQuantity',
    'hardAllocations', (
      select count(*)
      from app.inventory_allocations allocation
      where allocation.order_id = fixture_input.paid_order_id
        and allocation.status = 'reserved'
        and allocation.reconciliation_status = 'resolved'
    ),
    'readyLines', (
      select count(*)
      from app.order_lines line
      where line.order_id = fixture_input.paid_order_id
        and line.status = 'ready_for_pickup'
    ),
    'activeQr', (
      select count(*)
      from private.qr_order_identities identity
      join private.qr_order_locators locator
        on locator.identity_id = identity.id
       and locator.active
      where identity.order_id = fixture_input.paid_order_id
        and identity.suspended_at is null
    ),
    'allQr', (
      select count(*)
      from private.qr_order_identities identity
      join private.qr_order_locators locator
        on locator.identity_id = identity.id
      where identity.order_id = fixture_input.paid_order_id
    ),
    'qrBusinessEligible',
      private.order_qr_business_eligible(fixture_input.paid_order_id),
    'qrUsable', private.order_qr_usable(fixture_input.paid_order_id),
    'provisionStatus', provision_result->>'status',
    'transactionRolledBack', true
  )
  into result
  from app.payments payment
  where payment.order_id = fixture_input.paid_order_id
    and payment.status = 'paid';

  if result is null
    or result->>'provisionStatus' <> 'active'
    or (result->>'hardAllocations')::integer <> 1
    or (result->>'readyLines')::integer <> 1
    or (result->>'activeQr')::integer <> 1
    or not (result->>'qrBusinessEligible')::boolean
    or not (result->>'qrUsable')::boolean
  then
    raise exception 'MOLLIE_ACCEPTANCE_READINESS_PROOF_FAILED'
      using errcode = '23514';
  end if;

  insert into mollie_acceptance_readiness_result(value) values(result);
end
$fixture$;

select value from mollie_acceptance_readiness_result;
rollback;
