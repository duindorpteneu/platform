-- Package-first payment hardening.
--
-- Manual cash registration is administrator/AAL2-only, retry-stable and keeps
-- the supplied business reason in a restricted immutable ledger. Mollie
-- metadata is bound to the explicit member-season. Neither path creates a QR:
-- QR activation is owned by the later paid + hard-allocation readiness flow.

alter table app.payments
  add column member_season_id uuid,
  add column package_snapshot_id uuid,
  add column metadata_schema_version smallint,
  add column manual_request_id uuid,
  add column manual_reason text,
  add column recorded_by uuid references app.staff_profiles(auth_user_id) on delete restrict;

update app.payments payment
set member_season_id = orders.member_season_id,
    package_snapshot_id = orders.active_package_snapshot_id,
    metadata_schema_version = case
      when payment.method = 'mollie' then 1
      else null
    end
from app.member_orders orders
where orders.id = payment.order_id;

alter table app.payments
  alter column member_season_id set not null,
  alter column package_snapshot_id set not null,
  add constraint payments_member_season_order_fkey
    foreign key (order_id, member_season_id)
    references app.member_orders(id, member_season_id)
    on delete restrict
    deferrable initially deferred,
  add constraint payments_package_snapshot_order_fkey
    foreign key (package_snapshot_id, order_id)
    references app.order_package_snapshots(id, order_id)
    on delete restrict
    deferrable initially deferred,
  add constraint payments_metadata_schema_version_check check (
    metadata_schema_version is null
    or (
      method = 'mollie'
      and metadata_schema_version in (1, 2)
    )
  );

create or replace function app.fill_payment_domain_snapshot()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  active_snapshot uuid;
  active_member_season uuid;
begin
  select active_package_snapshot_id, member_season_id
  into active_snapshot, active_member_season
  from app.member_orders
  where id = new.order_id;
  if active_snapshot is null or active_member_season is null then
    raise exception 'ORDER_PACKAGE_SNAPSHOT_REQUIRED' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' and new.member_season_id is null then
    new.member_season_id := active_member_season;
  end if;
  if tg_op = 'INSERT' and new.package_snapshot_id is null then
    new.package_snapshot_id := active_snapshot;
  end if;
  if new.package_snapshot_id <> active_snapshot
    or new.member_season_id <> active_member_season
  then
    raise exception 'PAYMENT_PACKAGE_SNAPSHOT_MISMATCH' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE'
    and (
      old.package_snapshot_id is distinct from new.package_snapshot_id
      or old.member_season_id is distinct from new.member_season_id
      or old.order_id is distinct from new.order_id
    )
  then
    raise exception 'PAYMENT_PACKAGE_SNAPSHOT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger payments_fill_domain_snapshot
before insert or update of member_season_id, package_snapshot_id, order_id on app.payments
for each row execute function app.fill_payment_domain_snapshot();

revoke all on function app.fill_payment_domain_snapshot()
from public, anon, authenticated, service_role;

create unique index payments_manual_request_unique_idx
  on app.payments(manual_request_id)
  where manual_request_id is not null;

alter table app.payments
  add constraint payments_manual_v2_contract check (
    manual_request_id is null
    or (
      method in ('cash', 'card')
      and status in ('paid', 'refunded')
      and recorded_by is not null
      and manual_reason is not null
      and manual_reason = trim(manual_reason)
      and length(manual_reason) between 4 and 500
    )
  );

create or replace function private.guard_manual_payment_metadata()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if old.manual_request_id is distinct from new.manual_request_id
    or old.manual_reason is distinct from new.manual_reason
    or old.recorded_by is distinct from new.recorded_by
  then
    raise exception 'MANUAL_PAYMENT_METADATA_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger payments_manual_metadata_immutable
before update of manual_request_id, manual_reason, recorded_by on app.payments
for each row execute function private.guard_manual_payment_metadata();

revoke all on function private.guard_manual_payment_metadata()
from public, anon, authenticated, service_role;

drop policy if exists "operations can manage payments" on app.payments;
create policy "operations can read payments" on app.payments
for select using (
  app.staff_role() in ('beheerder', 'kledingcommissie')
);

create table private.manual_payment_requests (
  request_id uuid primary key,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  payment_id uuid not null unique references app.payments(id) on delete restrict,
  actor_user_id uuid not null references app.staff_profiles(auth_user_id) on delete restrict,
  method app.payment_method not null check (method in ('cash', 'card')),
  amount_cents integer not null check (amount_cents > 0),
  reason text not null check (
    reason = trim(reason)
    and length(reason) between 4 and 500
  ),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
    and not result_snapshot ?| array[
      'email', 'recipient', 'name', 'member_name', 'token', 'token_hash',
      'qr_token', 'qr_hash', 'checkout_url'
    ]
  ),
  recorded_at timestamptz not null default timezone('utc', now())
);

alter table private.manual_payment_requests enable row level security;
revoke all on table private.manual_payment_requests
from public, anon, authenticated, service_role;

create or replace function private.reject_manual_payment_request_mutation()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  raise exception 'MANUAL_PAYMENT_REQUEST_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger manual_payment_requests_immutable
before update or delete on private.manual_payment_requests
for each row execute function private.reject_manual_payment_request_mutation();

revoke all on function private.reject_manual_payment_request_mutation()
from public, anon, authenticated, service_role;

create or replace function app.record_manual_payment_v2(
  p_order_id uuid,
  p_method app.payment_method,
  p_amount_cents integer,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target_order app.member_orders%rowtype;
  existing_request private.manual_payment_requests%rowtype;
  normalized_reason text;
  computed_hash text;
  payment_id uuid;
  result jsonb;
  card_enabled boolean := false;
begin
  normalized_reason := regexp_replace(trim(coalesce(p_reason, '')), '[[:space:]]+', ' ', 'g');
  if p_order_id is null
    or p_request_id is null
    or p_amount_cents is null
    or p_amount_cents <= 0
    or p_method not in ('cash', 'card')
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'INVALID_MANUAL_PAYMENT' using errcode = '22023';
  end if;

  select enabled into card_enabled
  from app.release_feature_flags
  where key = 'legacy_card_payment';
  if p_method = 'card' and not coalesce(card_enabled, false) then
    raise exception 'LEGACY_CARD_PAYMENT_DISABLED' using errcode = '55000';
  end if;

  computed_hash := encode(extensions.digest(
    convert_to(jsonb_build_object(
      'orderId', p_order_id,
      'method', p_method::text,
      'amountCents', p_amount_cents,
      'reason', normalized_reason
    )::text, 'UTF8'),
    'sha256'
  ), 'hex');

  select orders.* into target_order
  from app.member_orders orders
  join app.member_seasons member_season
    on member_season.id = orders.member_season_id
    and member_season.member_id = orders.member_id
    and member_season.season_id = orders.season_id
    and member_season.participation_status = 'active'
    and member_season.reconciliation_status = 'resolved'
  join app.seasons season
    on season.id = orders.season_id
    and season.status = 'open'
  join app.app_settings settings
    on settings.id = true
    and settings.active_season_id = orders.season_id
  where orders.id = p_order_id
  for update of orders;
  if not found then
    raise exception 'ORDER_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  select * into existing_request
  from private.manual_payment_requests
  where request_id = p_request_id;
  if found then
    if existing_request.order_id <> p_order_id
      or existing_request.actor_user_id <> actor
      or existing_request.request_hash <> computed_hash
    then
      raise exception 'MANUAL_PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return existing_request.result_snapshot || jsonb_build_object('reused', true);
  end if;

  if target_order.amount_due_cents <> p_amount_cents then
    raise exception 'MANUAL_PAYMENT_AMOUNT_MISMATCH' using errcode = '23514';
  end if;
  if exists(
    select 1 from app.payments payment
    where payment.order_id = target_order.id
      and payment.status = 'paid'
  ) then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23505';
  end if;
  if exists(
    select 1 from app.payments payment
    where payment.order_id = target_order.id
      and (
        payment.status = 'duplicate_paid'
        or payment.reconciliation_issue is not null
      )
  ) then
    raise exception 'PAYMENT_RECONCILIATION_OPEN' using errcode = '23514';
  end if;
  if exists(
    select 1 from app.payments payment
    where payment.order_id = target_order.id
      and payment.method = 'mollie'
      and payment.status in ('open', 'pending')
  ) then
    raise exception 'MOLLIE_ATTEMPT_ACTIVE' using errcode = '23514';
  end if;

  insert into app.payments(
    order_id,
    method,
    status,
    amount_cents,
    currency,
    idempotency_key,
    paid_at,
    manual_request_id,
    manual_reason,
    recorded_by
  ) values (
    target_order.id,
    p_method,
    'paid',
    target_order.amount_due_cents,
    'EUR',
    'manual:v2:' || p_request_id::text,
    timezone('utc', now()),
    p_request_id,
    normalized_reason,
    actor
  )
  returning id into payment_id;

  result := jsonb_build_object(
    'paymentId', payment_id,
    'orderId', target_order.id,
    'memberSeasonId', target_order.member_season_id,
    'seasonId', target_order.season_id,
    'status', 'paid',
    'amountCents', target_order.amount_due_cents,
    'currency', 'EUR',
    'method', p_method::text,
    'qrStatus', 'inactive_until_allocated',
    'reused', false
  );

  insert into private.manual_payment_requests(
    request_id,
    order_id,
    payment_id,
    actor_user_id,
    method,
    amount_cents,
    reason,
    request_hash,
    result_snapshot
  ) values (
    p_request_id,
    target_order.id,
    payment_id,
    actor,
    p_method,
    target_order.amount_due_cents,
    normalized_reason,
    computed_hash,
    result
  );

  perform private.enqueue_order_email(
    target_order.id,
    'payment_received',
    'transaction:payment_received:' || payment_id::text
  );
  perform app.refresh_order_status(target_order.id);

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'payment.manual.recorded_v2',
    'member_order',
    target_order.id,
    jsonb_build_object(
      'payment_id', payment_id,
      'manual_request_id', p_request_id,
      'method', p_method::text,
      'amount_cents', target_order.amount_due_cents,
      'currency', 'EUR',
      'reason_sha256', encode(extensions.digest(convert_to(normalized_reason, 'UTF8'), 'sha256'), 'hex'),
      'reason_recorded', true,
      'qr_activated', false
    ),
    p_correlation_id
  );

  return result;
end;
$$;

revoke all on function app.record_manual_payment_v2(
  uuid, app.payment_method, integer, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.record_manual_payment_v2(
  uuid, app.payment_method, integer, text, uuid, uuid
) to authenticated;

create or replace function public.prepare_mollie_payment(
  p_token_hash text,
  p_order_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  target_payment app.payments%rowtype;
  now_utc timestamptz := timezone('utc', now());
  reused boolean := false;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$'
    or length(trim(p_idempotency_key)) not between 8 and 160
  then
    raise exception 'INVALID_PAYMENT_REQUEST' using errcode = '22023';
  end if;

  select orders.* into target_order
  from private.parent_sessions session
  join lateral private.parent_authorized_member_seasons(
    session.parent_account_id
  ) authorized on true
  join app.member_seasons member_season
    on member_season.id = authorized.member_season_id
    and member_season.participation_status = 'active'
    and member_season.reconciliation_status = 'resolved'
  join app.member_orders orders
    on orders.member_season_id = member_season.id
  join app.app_settings settings
    on settings.id = true
    and settings.active_season_id = orders.season_id
  join app.seasons season
    on season.id = orders.season_id
    and season.status = 'open'
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > now_utc
    and orders.id = p_order_id
  for update of orders;
  if not found then
    raise exception 'PARENT_ORDER_ACCESS_DENIED' using errcode = '42501';
  end if;

  if exists(
    select 1 from app.payments payment
    where payment.order_id = target_order.id
      and payment.status = 'paid'
  ) then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23514';
  end if;
  if exists(
    select 1 from app.payments payment
    where payment.order_id = target_order.id
      and (
        payment.status = 'duplicate_paid'
        or payment.reconciliation_issue is not null
      )
  ) then
    raise exception 'PAYMENT_RECONCILIATION_OPEN' using errcode = '23514';
  end if;

  select * into target_payment
  from app.payments payment
  where payment.idempotency_key = trim(p_idempotency_key)
  for update;
  if found then
    if target_payment.order_id <> target_order.id then
      raise exception 'PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if target_payment.status not in ('open', 'pending') then
      raise exception 'PAYMENT_ATTEMPT_NOT_REUSABLE' using errcode = '23514';
    end if;
    if target_payment.package_snapshot_id <> target_order.active_package_snapshot_id then
      raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
    end if;
    if target_payment.metadata_schema_version = 1
      and target_payment.provider_payment_id is null
    then
      raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
    end if;
    if (
      target_payment.provider_payment_id is null
      and target_payment.created_at + interval '1 hour' <= now_utc
    ) or (
      target_payment.provider_payment_id is not null
      and (
        target_payment.checkout_url is null
        or target_payment.provider_expires_at <= now_utc
      )
    ) then
      raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
    end if;
    reused := true;
  else
    select * into target_payment
    from app.payments payment
    where payment.order_id = target_order.id
      and payment.method = 'mollie'
      and payment.status in ('open', 'pending')
    order by payment.created_at desc
    limit 1
    for update;
    if found then
      if target_payment.package_snapshot_id <> target_order.active_package_snapshot_id then
        raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
      end if;
      if target_payment.metadata_schema_version = 1
        and target_payment.provider_payment_id is null
      then
        raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
      end if;
      if (
        target_payment.provider_payment_id is null
        and target_payment.created_at + interval '1 hour' <= now_utc
      ) or (
        target_payment.provider_payment_id is not null
        and (
          target_payment.checkout_url is null
          or target_payment.provider_expires_at <= now_utc
        )
      ) then
        raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
      end if;
      reused := true;
    else
      insert into app.payments(
        order_id,
        method,
        status,
        amount_cents,
        currency,
        idempotency_key,
        metadata_schema_version
      ) values (
        target_order.id,
        'mollie',
        'open',
        target_order.amount_due_cents,
        'EUR',
        trim(p_idempotency_key),
        2
      )
      returning * into target_payment;
    end if;
  end if;

  return jsonb_build_object(
    'paymentId', target_payment.id,
    'orderId', target_order.id,
    'amountCents', target_order.amount_due_cents,
    'currency', 'EUR',
    'status', target_payment.status::text,
    'providerPaymentId', target_payment.provider_payment_id,
    'checkoutUrl', target_payment.checkout_url,
    'reused', reused,
    'idempotencyKey', target_payment.idempotency_key,
    'metadata', jsonb_build_object(
      'payment_id', target_payment.id,
      'order_id', target_order.id,
      'member_id', target_order.member_id,
      'member_season_id', target_order.member_season_id,
      'season_id', target_order.season_id,
      'schema_version', 2
    )
  );
end;
$$;

revoke all on function public.prepare_mollie_payment(text, uuid, text)
from public, anon, authenticated, service_role;
grant execute on function public.prepare_mollie_payment(text, uuid, text)
to service_role;

create or replace function app.get_mollie_reconciliation_context_v2(p_provider_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  if length(trim(coalesce(p_provider_id, ''))) not between 3 and 160 then
    raise exception 'INVALID_PROVIDER_PAYMENT_ID' using errcode = '22023';
  end if;
  select jsonb_build_object(
    'paymentId', payment.id,
    'providerPaymentId', payment.provider_payment_id,
    'paymentStatus', payment.status::text,
    'amountCents', payment.amount_cents,
    'currency', payment.currency,
    'metadataSchemaVersion', payment.metadata_schema_version,
    'orderId', orders.id,
    'memberId', orders.member_id,
    'memberSeasonId', orders.member_season_id,
    'seasonId', orders.season_id,
    'amountDueCents', orders.amount_due_cents
  ) into result
  from app.payments payment
  join app.member_orders orders on orders.id = payment.order_id
  where payment.provider_payment_id = trim(p_provider_id);
  if result is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  return result;
end;
$$;

revoke all on function app.get_mollie_reconciliation_context_v2(text)
from public, anon, authenticated, service_role;
grant execute on function app.get_mollie_reconciliation_context_v2(text)
to service_role;

create or replace function app.reconcile_mollie_payment_v2(
  p_event_key text,
  p_provider_id text,
  p_local_payment_id uuid,
  p_metadata_payment_id uuid,
  p_order_id uuid,
  p_member_id uuid,
  p_member_season_id uuid,
  p_season_id uuid,
  p_amount_cents integer,
  p_currency text,
  p_status app.payment_status,
  p_provider_created_at timestamptz,
  p_provider_updated_at timestamptz,
  p_provider_expires_at timestamptz,
  p_paid_at timestamptz,
  p_refunded_at timestamptz,
  p_validation_issue text default null,
  p_observation jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_payment app.payments%rowtype;
  target_order app.member_orders%rowtype;
  existing_event private.payment_events%rowtype;
  primary_payment_id uuid;
  issue text;
  safe_observation jsonb;
  event_type text;
  effect text := 'updated';
  resulting_status app.payment_status;
  was_primary_paid boolean;
  result jsonb;
begin
  if length(trim(coalesce(p_event_key, ''))) not between 8 and 240
    or length(trim(coalesce(p_provider_id, ''))) not between 3 and 160
    or p_local_payment_id is null
    or p_provider_updated_at is null
    or p_status = 'duplicate_paid'
    or jsonb_typeof(coalesce(p_observation, '{}'::jsonb)) <> 'object'
  then
    raise exception 'INVALID_MOLLIE_RECONCILIATION' using errcode = '22023';
  end if;
  if p_validation_issue is not null
    and p_validation_issue not in (
      'MOLLIE_METADATA_INVALID',
      'MOLLIE_METADATA_MISSING',
      'MOLLIE_METADATA_SCHEMA_INVALID'
    )
  then
    raise exception 'INVALID_VALIDATION_ISSUE' using errcode = '22023';
  end if;

  select * into existing_event
  from private.payment_events
  where idempotency_key = trim(p_event_key);
  if found then
    return jsonb_build_object(
      'paymentId', existing_event.payment_id,
      'status', 'replay',
      'effect', 'event_replay',
      'eventType', existing_event.event_type
    );
  end if;

  select * into target_payment
  from app.payments
  where id = p_local_payment_id
    and provider_payment_id = trim(p_provider_id);
  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into target_order
  from app.member_orders
  where id = target_payment.order_id
  for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into existing_event
  from private.payment_events
  where idempotency_key = trim(p_event_key);
  if found then
    return jsonb_build_object(
      'paymentId', existing_event.payment_id,
      'status', 'replay',
      'effect', 'event_replay',
      'eventType', existing_event.event_type
    );
  end if;

  select * into target_payment
  from app.payments
  where id = p_local_payment_id
    and provider_payment_id = trim(p_provider_id)
  for update;
  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  issue := case
    when p_validation_issue is not null then p_validation_issue
    when p_metadata_payment_id is null then 'MOLLIE_METADATA_MISSING'
    when p_metadata_payment_id <> target_payment.id then 'MOLLIE_METADATA_PAYMENT_MISMATCH'
    when target_payment.metadata_schema_version is null
      or not (p_observation->>'schema_version') ~ '^[0-9]+$'
      or (p_observation->>'schema_version')::integer <> target_payment.metadata_schema_version
      then 'MOLLIE_METADATA_SCHEMA_MISMATCH'
    when p_order_id <> target_order.id
      or p_member_id <> target_order.member_id
      or p_member_season_id <> target_order.member_season_id
      or p_season_id <> target_order.season_id
      then 'PAYMENT_METADATA_MISMATCH'
    when target_payment.package_snapshot_id <> target_order.active_package_snapshot_id
      then 'PAYMENT_PACKAGE_SNAPSHOT_MISMATCH'
    when target_payment.method <> 'mollie'
      or target_payment.amount_cents <> p_amount_cents
      or target_order.amount_due_cents <> p_amount_cents
      or p_currency <> 'EUR'
      or target_payment.currency <> 'EUR'
      then 'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH'
    else null
  end;

  safe_observation := jsonb_strip_nulls(jsonb_build_object(
    'provider_id', left(trim(p_provider_id), 160),
    'status', p_status::text,
    'amount_cents', p_amount_cents,
    'currency', left(coalesce(p_currency, ''), 3),
    'provider_created_at', p_provider_created_at,
    'provider_updated_at', p_provider_updated_at,
    'provider_expires_at', p_provider_expires_at,
    'schema_version', case
      when (p_observation->>'schema_version') ~ '^[0-9]+$'
      then (p_observation->>'schema_version')::integer
      else null
    end
  ));

  if issue is not null then
    update app.payments
    set reconciliation_issue = left(issue, 500),
        reconciled_at = timezone('utc', now())
    where id = target_payment.id;
    insert into private.payment_events(
      payment_id,
      event_type,
      provider_payload_redacted,
      idempotency_key
    ) values (
      target_payment.id,
      'mismatch',
      safe_observation || jsonb_build_object('issue', issue),
      trim(p_event_key)
    );
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    ) values (
      null,
      'payment.mollie.manual_review',
      'payment',
      target_payment.id,
      jsonb_build_object('issue', issue, 'provider_status', p_status::text)
    );
    return jsonb_build_object(
      'paymentId', target_payment.id,
      'status', 'manual_review',
      'effect', 'mismatch',
      'issue', issue
    );
  end if;

  if target_payment.provider_updated_at is not null
    and p_provider_updated_at < target_payment.provider_updated_at
  then
    effect := 'stale_ignored';
  elsif p_status = 'paid' then
    if target_payment.status = 'paid' then
      effect := 'already_processed';
    elsif target_payment.status = 'refunded' then
      effect := 'terminal_ignored';
    else
      select id into primary_payment_id
      from app.payments
      where order_id = target_order.id
        and status = 'paid'
        and id <> target_payment.id
      order by paid_at, created_at
      limit 1
      for update;
      if primary_payment_id is not null then
        update app.payments
        set status = 'duplicate_paid',
            paid_at = coalesce(paid_at, p_paid_at, p_provider_updated_at),
            provider_created_at = coalesce(provider_created_at, p_provider_created_at),
            provider_updated_at = p_provider_updated_at,
            provider_expires_at = p_provider_expires_at,
            reconciled_at = timezone('utc', now()),
            reconciliation_issue = 'duplicate paid payment; manual reconciliation required'
        where id = target_payment.id;
        effect := 'duplicate_paid';
      else
        update app.payments
        set status = 'paid',
            paid_at = coalesce(paid_at, p_paid_at, p_provider_updated_at),
            provider_created_at = coalesce(provider_created_at, p_provider_created_at),
            provider_updated_at = p_provider_updated_at,
            provider_expires_at = p_provider_expires_at,
            reconciled_at = timezone('utc', now()),
            reconciliation_issue = null
        where id = target_payment.id;
        perform private.enqueue_order_email(
          target_order.id,
          'payment_received',
          'transaction:payment_received:' || target_payment.id::text
        );
        perform app.refresh_order_status(target_order.id);
        insert into app.audit_logs(
          actor_user_id,
          action,
          entity_type,
          entity_id,
          metadata
        ) values (
          null,
          'payment.mollie.paid_v2',
          'member_order',
          target_order.id,
          jsonb_build_object(
            'payment_id', target_payment.id,
            'member_season_id', target_order.member_season_id,
            'amount_cents', target_order.amount_due_cents,
            'currency', 'EUR',
            'qr_activated', false
          )
        );
        effect := 'paid';
      end if;
    end if;
  elsif p_status = 'refunded' then
    if target_payment.status = 'refunded' then
      effect := 'already_processed';
    else
      was_primary_paid := target_payment.status = 'paid';
      update app.payments
      set status = 'refunded',
          refunded_at = coalesce(refunded_at, p_refunded_at, p_provider_updated_at),
          provider_created_at = coalesce(provider_created_at, p_provider_created_at),
          provider_updated_at = p_provider_updated_at,
          provider_expires_at = p_provider_expires_at,
          reconciled_at = timezone('utc', now()),
          reconciliation_issue = case
            when target_payment.status = 'duplicate_paid'
            then 'duplicate payment refunded'
            else null
          end
      where id = target_payment.id;
      if was_primary_paid then
        update private.qr_tokens
        set active = false,
            revoked_at = coalesce(revoked_at, timezone('utc', now())),
            revocation_reason = coalesce(revocation_reason, 'Mollie payment refunded')
        where order_id = target_order.id
          and active;
        perform app.refresh_order_status(target_order.id);
      end if;
      insert into app.audit_logs(
        actor_user_id,
        action,
        entity_type,
        entity_id,
        metadata
      ) values (
        null,
        'payment.mollie.refunded_v2',
        'member_order',
        target_order.id,
        jsonb_build_object(
          'payment_id', target_payment.id,
          'member_season_id', target_order.member_season_id,
          'qr_blocked', was_primary_paid
        )
      );
      effect := 'refunded';
    end if;
  else
    if target_payment.status in ('paid', 'refunded') then
      effect := 'terminal_ignored';
    else
      update app.payments
      set status = p_status,
          provider_created_at = coalesce(provider_created_at, p_provider_created_at),
          provider_updated_at = p_provider_updated_at,
          provider_expires_at = p_provider_expires_at,
          reconciled_at = timezone('utc', now())
      where id = target_payment.id;
    end if;
  end if;

  if effect in ('already_processed', 'terminal_ignored') then
    update app.payments
    set provider_updated_at = greatest(
          coalesce(provider_updated_at, p_provider_updated_at),
          p_provider_updated_at
        ),
        reconciled_at = timezone('utc', now())
    where id = target_payment.id;
  end if;

  select status into resulting_status
  from app.payments
  where id = target_payment.id;

  result := jsonb_build_object(
    'paymentId', target_payment.id,
    'orderId', target_order.id,
    'memberSeasonId', target_order.member_season_id,
    'status', resulting_status::text,
    'effect', effect,
    'qrStatus', case
      when exists(
        select 1 from private.qr_tokens token
        where token.order_id = target_order.id
          and token.active
      ) then 'active'
      else 'inactive'
    end
  );

  event_type := case effect
    when 'paid' then 'paid'
    when 'duplicate_paid' then 'duplicate_paid'
    when 'refunded' then 'refunded'
    when 'stale_ignored' then 'stale_ignored'
    when 'terminal_ignored' then 'terminal_ignored'
    when 'already_processed' then 'replay'
    else 'observed'
  end;
  insert into private.payment_events(
    payment_id,
    event_type,
    provider_payload_redacted,
    idempotency_key
  ) values (
    target_payment.id,
    event_type,
    safe_observation,
    trim(p_event_key)
  );

  return result || jsonb_build_object('eventType', event_type);
end;
$$;

revoke all on function app.reconcile_mollie_payment_v2(
  text, text, uuid, uuid, uuid, uuid, uuid, uuid, integer, text,
  app.payment_status, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, text, jsonb
) from public, anon, authenticated, service_role;
grant execute on function app.reconcile_mollie_payment_v2(
  text, text, uuid, uuid, uuid, uuid, uuid, uuid, integer, text,
  app.payment_status, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, text, jsonb
) to service_role;

-- Remove server-reachable legacy paths that coupled payment to QR creation.
revoke execute on function app.record_manual_payment_with_qr_trusted(
  uuid, uuid, app.payment_method, text, text
) from service_role;
revoke execute on function app.reconcile_mollie_payment(
  text, text, uuid, uuid, uuid, uuid, uuid, integer, text,
  app.payment_status, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer, text, text, jsonb
) from service_role;
