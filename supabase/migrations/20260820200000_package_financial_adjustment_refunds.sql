-- Paid package corrections preserve factual payment history. Coverage moves to
-- a replacement assignment only through this immutable adjustment ledger;
-- price differences become a new payment or refund movement.

drop index if exists app.payments_one_paid_order_idx;
create unique index payments_one_paid_package_snapshot_idx
  on app.payments(order_id, package_snapshot_id)
  where status = 'paid';

create table app.package_financial_adjustments (
  id uuid primary key default gen_random_uuid(),
  package_change_request_id uuid not null unique
    references app.package_change_requests(id) on delete restrict,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  from_package_snapshot_id uuid not null,
  to_package_snapshot_id uuid not null,
  from_package_revision_id uuid,
  to_package_revision_id uuid not null
    references app.package_template_revisions(id) on delete restrict,
  original_paid_cents integer not null check (original_paid_cents >= 0),
  applied_credit_cents integer not null check (applied_credit_cents >= 0),
  additional_due_cents integer not null check (additional_due_cents >= 0),
  refund_due_cents integer not null check (refund_due_cents >= 0),
  currency text not null check (currency = 'EUR'),
  status text not null check (status = 'applied'),
  created_by uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  reason text not null check (
    reason = btrim(reason) and length(reason) between 4 and 480
  ),
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now()),
  constraint package_adjustment_from_snapshot_order_fkey
    foreign key(from_package_snapshot_id, order_id)
    references app.order_package_snapshots(id, order_id) on delete restrict,
  constraint package_adjustment_to_snapshot_order_fkey
    foreign key(to_package_snapshot_id, order_id)
    references app.order_package_snapshots(id, order_id) on delete restrict,
  constraint package_adjustment_member_season_order_fkey
    foreign key(order_id, member_season_id)
    references app.member_orders(id, member_season_id) on delete restrict,
  constraint package_adjustment_amounts_check check (
    from_package_snapshot_id <> to_package_snapshot_id
    and applied_credit_cents <= original_paid_cents
    and applied_credit_cents + refund_due_cents = original_paid_cents
  )
);

create unique index package_adjustments_from_snapshot_idx
  on app.package_financial_adjustments(from_package_snapshot_id);
create unique index package_adjustments_to_snapshot_idx
  on app.package_financial_adjustments(to_package_snapshot_id);
create index package_adjustments_order_history_idx
  on app.package_financial_adjustments(order_id, created_at desc);

create table app.package_credit_allocations (
  adjustment_id uuid not null
    references app.package_financial_adjustments(id) on delete restrict,
  payment_id uuid not null references app.payments(id) on delete restrict,
  amount_cents integer not null check (amount_cents > 0),
  currency text not null check (currency = 'EUR'),
  created_at timestamptz not null default timezone('utc', now()),
  primary key(adjustment_id, payment_id)
);
create index package_credit_allocations_payment_idx
  on app.package_credit_allocations(payment_id);

create table app.package_refunds (
  id uuid primary key default gen_random_uuid(),
  adjustment_id uuid not null
    references app.package_financial_adjustments(id) on delete restrict,
  payment_id uuid not null references app.payments(id) on delete restrict,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  method app.payment_method not null,
  amount_cents integer not null check (amount_cents > 0),
  currency text not null check (currency = 'EUR'),
  status text not null check (status in (
    'due', 'requesting', 'queued', 'pending', 'processing', 'completed',
    'failed', 'canceled', 'manual_due', 'manual_completed',
    'reconciliation_required'
  )),
  provider_refund_id text unique,
  provider_status text check (provider_status is null or provider_status in (
    'queued', 'pending', 'processing', 'refunded', 'failed', 'canceled'
  )),
  operation_request_id uuid unique,
  idempotency_key text unique,
  requested_at timestamptz,
  provider_accepted_at timestamptz,
  completed_at timestamptz,
  reconciled_at timestamptz,
  failed_at timestamptz,
  failure_code text check (
    failure_code is null or failure_code ~ '^[A-Z][A-Z0-9_]{2,79}$'
  ),
  retryable boolean not null default false,
  manual_reason text,
  manual_evidence_reference text,
  completed_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique(adjustment_id, payment_id),
  constraint package_refund_method_state_check check (
    (method = 'mollie' and status not in ('manual_due', 'manual_completed'))
    or (method in ('cash', 'card') and status in ('manual_due', 'manual_completed'))
  ),
  constraint package_refund_manual_evidence_check check (
    (status <> 'manual_completed' and manual_reason is null
      and manual_evidence_reference is null and completed_by is null)
    or (status = 'manual_completed'
      and length(btrim(manual_reason)) between 4 and 500
      and length(btrim(manual_evidence_reference)) between 4 and 160
      and completed_by is not null and completed_at is not null)
  )
);
create index package_refunds_adjustment_idx
  on app.package_refunds(adjustment_id, status);
create index package_refunds_order_status_idx
  on app.package_refunds(order_id, status, created_at desc);
create index package_refunds_payment_idx
  on app.package_refunds(payment_id);

alter table app.package_financial_adjustments enable row level security;
alter table app.package_credit_allocations enable row level security;
alter table app.package_refunds enable row level security;
revoke all on table app.package_financial_adjustments,
  app.package_credit_allocations, app.package_refunds
from public, anon, authenticated, service_role;

create or replace function private.reject_package_financial_history_mutation()
returns trigger language plpgsql set search_path = private, pg_temp as $$
begin
  raise exception 'PACKAGE_FINANCIAL_HISTORY_IMMUTABLE' using errcode = '23514';
end;
$$;
create trigger package_financial_adjustments_immutable
before update or delete on app.package_financial_adjustments
for each row execute function private.reject_package_financial_history_mutation();
create trigger package_credit_allocations_immutable
before update or delete on app.package_credit_allocations
for each row execute function private.reject_package_financial_history_mutation();

create or replace function private.protect_package_refund_mutation()
returns trigger language plpgsql set search_path = private, pg_temp as $$
begin
  if current_setting('app.package_refund_internal', true) is distinct from 'on' then
    raise exception 'PACKAGE_REFUND_MUTATION_FORBIDDEN' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'PACKAGE_REFUND_IMMUTABLE' using errcode = '23514';
  end if;
  if old.adjustment_id is distinct from new.adjustment_id
    or old.payment_id is distinct from new.payment_id
    or old.order_id is distinct from new.order_id
    or old.method is distinct from new.method
    or old.amount_cents is distinct from new.amount_cents
    or old.currency is distinct from new.currency
    or old.created_at is distinct from new.created_at
  then
    raise exception 'PACKAGE_REFUND_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  new.updated_at := timezone('utc', now());
  return new;
end;
$$;
create trigger package_refunds_protect
before update or delete on app.package_refunds
for each row execute function private.protect_package_refund_mutation();

revoke all on function private.reject_package_financial_history_mutation(),
  private.protect_package_refund_mutation()
from public, anon, authenticated, service_role;

create or replace function private.order_financial_balance(p_order_id uuid)
returns table(
  active_package_price_cents integer,
  adjustment_id uuid,
  applied_credit_cents integer,
  successful_payment_cents integer,
  remaining_due_cents integer,
  refund_due_cents integer,
  refund_completed_cents integer,
  refund_outstanding_cents integer,
  reconciliation_conflict_count integer,
  effective_status text,
  settled_at timestamptz
)
language sql stable security definer
set search_path = app, private, pg_temp as $$
  with target as (
    select orders.id, orders.active_package_snapshot_id,
      snapshot.package_price_cents active_price
    from app.member_orders orders
    join app.order_package_snapshots snapshot
      on snapshot.id = orders.active_package_snapshot_id
      and snapshot.order_id = orders.id
    where orders.id = p_order_id
  ), adjustment as (
    select financial.*
    from target
    left join app.package_financial_adjustments financial
      on financial.to_package_snapshot_id = target.active_package_snapshot_id
  ), active_payments as (
    select coalesce(sum(payment.amount_cents) filter (
        where payment.status = 'paid' and payment.reconciliation_issue is null
      ), 0)::integer paid_cents,
      max(payment.paid_at) filter (
        where payment.status = 'paid' and payment.reconciliation_issue is null
      ) paid_at,
      count(*) filter (
        where payment.status = 'duplicate_paid'
          or payment.reconciliation_issue is not null
      )::integer conflict_count,
      bool_or(payment.status = 'pending') pending_payment,
      bool_or(payment.status = 'open') open_payment,
      bool_or(payment.status = 'refunded') refunded_payment
    from target
    left join app.payments payment
      on payment.order_id = target.id
      and payment.package_snapshot_id = target.active_package_snapshot_id
  ), refunds as (
    select coalesce(sum(refund.amount_cents), 0)::integer refund_due,
      coalesce(sum(refund.amount_cents) filter (
        where refund.status in ('completed', 'manual_completed')
      ), 0)::integer refund_completed,
      count(*) filter (where refund.status = 'reconciliation_required')::integer
        refund_conflicts
    from adjustment
    left join app.package_refunds refund on refund.adjustment_id = adjustment.id
  ), calculated as (
    select target.active_price,
      adjustment.id adjustment_id,
      coalesce(adjustment.applied_credit_cents, 0) credit_cents,
      active_payments.paid_cents,
      greatest(target.active_price
        - coalesce(adjustment.applied_credit_cents, 0)
        - active_payments.paid_cents, 0)::integer remaining,
      coalesce(adjustment.refund_due_cents, refunds.refund_due, 0)::integer refund_due,
      refunds.refund_completed,
      active_payments.conflict_count + refunds.refund_conflicts conflicts,
      active_payments.pending_payment,
      active_payments.open_payment,
      active_payments.refunded_payment,
      greatest(adjustment.created_at, active_payments.paid_at) settled_at
    from target cross join active_payments cross join refunds
    left join adjustment on true
  )
  select calculated.active_price, calculated.adjustment_id,
    calculated.credit_cents, calculated.paid_cents, calculated.remaining,
    calculated.refund_due, calculated.refund_completed,
    greatest(calculated.refund_due - calculated.refund_completed, 0)::integer,
    calculated.conflicts,
    case
      when calculated.conflicts > 0 then 'reconciliation_required'
      when calculated.remaining = 0 then 'paid'
      when calculated.pending_payment then 'pending'
      when calculated.open_payment then 'open'
      when calculated.refunded_payment then 'refunded'
      else 'open'
    end,
    case when calculated.remaining = 0 then calculated.settled_at else null end
  from calculated;
$$;
revoke all on function private.order_financial_balance(uuid)
from public, anon, authenticated, service_role;

create or replace function private.order_payment_projection(p_order_id uuid)
returns table(
  effective_status text,
  valid_payment_id uuid,
  paid_at timestamptz,
  conflict_count integer
)
language sql stable security definer
set search_path = app, private, pg_temp as $$
  select balance.effective_status,
    case when balance.effective_status = 'paid' then (
      select candidate.payment_id
      from (
        select payment.id payment_id, payment.paid_at, 0 priority
        from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where payment.order_id = p_order_id and payment.status = 'paid'
          and payment.reconciliation_issue is null
          and payment.package_snapshot_id = orders.active_package_snapshot_id
        union all
        select payment.id, payment.paid_at, 1
        from app.package_financial_adjustments adjustment
        join app.package_credit_allocations allocation
          on allocation.adjustment_id = adjustment.id
        join app.payments payment on payment.id = allocation.payment_id
        join app.member_orders orders on orders.id = adjustment.order_id
          and orders.active_package_snapshot_id = adjustment.to_package_snapshot_id
        where adjustment.order_id = p_order_id and allocation.amount_cents > 0
          and payment.status = 'paid' and payment.reconciliation_issue is null
      ) candidate
      order by candidate.priority, candidate.paid_at desc, candidate.payment_id desc
      limit 1
    ) else null end,
    balance.settled_at,
    balance.reconciliation_conflict_count
  from private.order_financial_balance(p_order_id) balance;
$$;
create or replace function private.order_has_effective_paid_payment(p_order_id uuid)
returns boolean language sql stable security definer
set search_path = app, private, pg_temp as $$
  select balance.effective_status = 'paid'
  from private.order_financial_balance(p_order_id) balance;
$$;
create or replace function private.export_effective_payment_status(p_order_id uuid)
returns text language sql stable security definer
set search_path = app, private, pg_temp as $$
  select balance.effective_status
  from private.order_financial_balance(p_order_id) balance;
$$;
create or replace function private.order_effective_payment_status(p_order_id uuid)
returns text language sql stable security definer
set search_path = app, private, pg_temp as $$
  select case balance.effective_status
    when 'reconciliation_required' then 'open' else balance.effective_status end
  from private.order_financial_balance(p_order_id) balance;
$$;
revoke all on function private.order_payment_projection(uuid),
  private.order_has_effective_paid_payment(uuid),
  private.export_effective_payment_status(uuid),
  private.order_effective_payment_status(uuid)
from public, anon, authenticated, service_role;

create or replace function private.package_change_state_v2(
  p_order_id uuid, p_target_revision_id uuid
)
returns jsonb language plpgsql stable security definer
set search_path = app, private, pg_temp as $$
declare result jsonb;
begin
  with target_order as (
    select orders.*, current_snapshot.package_name from_name,
      current_snapshot.package_price_cents from_price,
      current_snapshot.currency from_currency,
      target.id target_revision_id, target.name target_name,
      target.price_cents target_price, target.currency target_currency
    from app.member_orders orders
    join app.order_package_snapshots current_snapshot
      on current_snapshot.id = orders.active_package_snapshot_id
    join app.package_template_revisions target
      on target.id = p_target_revision_id
      and target.season_id = orders.season_id
      and target.status = 'published' and target.active
    where orders.id = p_order_id
  ), current_adjustment as (
    select adjustment.* from target_order
    join app.package_financial_adjustments adjustment
      on adjustment.to_package_snapshot_id = target_order.active_package_snapshot_id
  ), sources as (
    select allocation.payment_id, allocation.amount_cents,
      payment.method::text method, payment.paid_at
    from current_adjustment
    join app.package_credit_allocations allocation
      on allocation.adjustment_id = current_adjustment.id
    join app.payments payment on payment.id = allocation.payment_id
    union all
    select payment.id, payment.amount_cents, payment.method::text, payment.paid_at
    from target_order
    join app.payments payment on payment.order_id = target_order.id
      and payment.package_snapshot_id = target_order.active_package_snapshot_id
      and payment.status = 'paid' and payment.reconciliation_issue is null
  ), source_summary as (
    select coalesce(sum(amount_cents), 0)::integer effective_paid,
      coalesce(jsonb_agg(jsonb_build_object(
        'paymentId', payment_id, 'method', method,
        'amountCents', amount_cents, 'paidAt', paid_at
      ) order by paid_at, payment_id), '[]'::jsonb) payment_sources,
      case when count(distinct method) = 0 then null
        when count(distinct method) = 1 then min(method) else 'mixed' end payment_method
    from sources
  ), counts as (
    select
      (select count(*)::integer from app.inventory_allocations allocation
        where allocation.order_id = target_order.id and allocation.status = 'reserved') reserved_count,
      (select count(*)::integer from app.inventory_allocations allocation
        where allocation.order_id = target_order.id and allocation.status = 'fulfilled') fulfilled_count,
      (select count(*)::integer from app.fulfilment_lines fulfilment_line
        join app.fulfilments fulfilment on fulfilment.id = fulfilment_line.fulfilment_id
        where fulfilment.order_id = target_order.id
          and fulfilment.reversed_at is null and fulfilment_line.reversed_at is null) fulfilment_count,
      (select count(*)::integer from app.inventory_reservations reservation
        join app.order_lines line on line.id = reservation.order_line_id
        where line.order_id = target_order.id
          and reservation.status in ('reserved', 'fulfilled')
          and not exists(select 1 from app.inventory_allocations allocation
            where allocation.legacy_reservation_id = reservation.id)) legacy_count,
      (select count(*)::integer from app.payments payment
        where payment.order_id = target_order.id
          and payment.status in ('open', 'pending')) unresolved_payment_count,
      (select count(*)::integer from app.payments payment
        where payment.order_id = target_order.id and (
          payment.status = 'duplicate_paid' or payment.reconciliation_issue is not null
        )) payment_conflicts,
      (select count(*)::integer from app.package_refunds refund
        join current_adjustment on current_adjustment.id = refund.adjustment_id
        where refund.status not in ('completed', 'manual_completed')) refund_blockers,
      (select count(*)::integer from app.package_template_items item
        where item.revision_id = target_order.target_revision_id) required_sizes,
      (select count(*)::integer from app.package_template_items item
        where item.revision_id = target_order.target_revision_id and exists(
          select 1 from app.member_article_sizes profile
          join app.article_variants variant
            on variant.id = profile.article_variant_id
            and variant.article_id = item.article_id and variant.active
          join app.article_seasons link on link.article_id = variant.article_id
            and link.season_id = target_order.season_id
          where profile.member_season_id = target_order.member_season_id
            and profile.article_id = item.article_id
            and profile.selection_status in ('confirmed', 'locked')
            and profile.confirmed_at is not null
        )) known_sizes
    from target_order
  )
  select jsonb_build_object(
    'orderId', target_order.id,
    'memberSeasonId', target_order.member_season_id,
    'seasonId', target_order.season_id,
    'fromSnapshotId', target_order.active_package_snapshot_id,
    'fromPackageRevisionId', target_order.package_revision_id,
    'fromPackageName', target_order.from_name,
    'fromPriceCents', target_order.from_price,
    'fromCurrency', target_order.from_currency,
    'toPackageRevisionId', target_order.target_revision_id,
    'toPackageName', target_order.target_name,
    'toPriceCents', target_order.target_price,
    'toCurrency', target_order.target_currency,
    'priceDeltaCents', target_order.target_price - target_order.from_price,
    'effectivePaidCents', source_summary.effective_paid,
    'creditAvailableCents', source_summary.effective_paid,
    'creditAppliedCents', least(source_summary.effective_paid, target_order.target_price),
    'additionalDueCents', greatest(target_order.target_price - source_summary.effective_paid, 0),
    'refundDueCents', greatest(source_summary.effective_paid - target_order.target_price, 0),
    'paymentMethod', source_summary.payment_method,
    'paymentSources', source_summary.payment_sources,
    'reservedAllocationCount', counts.reserved_count,
    'fulfilledAllocationCount', counts.fulfilled_count,
    'requiresAllocationRelease', counts.reserved_count > 0,
    'blockedByFulfilment', counts.fulfilled_count > 0 or counts.fulfilment_count > 0,
    'blockedByReconciliation', counts.legacy_count > 0
      or counts.payment_conflicts > 0 or counts.refund_blockers > 0,
    'unresolvedPaymentCount', counts.unresolved_payment_count,
    'targetPackageRequiredSizeCount', counts.required_sizes,
    'targetPackageKnownSizeCount', counts.known_sizes,
    'targetPackageMissingSizeCount', greatest(counts.required_sizes - counts.known_sizes, 0),
    'targetSizeSelections', coalesce((select jsonb_agg(jsonb_build_object(
      'articleId', item.article_id, 'variantId', profile.article_variant_id,
      'selectionStatus', profile.selection_status::text,
      'confirmedAt', profile.confirmed_at
    ) order by item.sort_order,item.article_id)
      from app.package_template_items item
      left join app.member_article_sizes profile
        on profile.member_season_id=target_order.member_season_id
        and profile.article_id=item.article_id
      where item.revision_id=target_order.target_revision_id),'[]'::jsonb),
    'canApply', counts.fulfilled_count = 0 and counts.fulfilment_count = 0
      and counts.legacy_count = 0 and counts.payment_conflicts = 0
      and counts.refund_blockers = 0 and counts.unresolved_payment_count = 0
  ) into result
  from target_order cross join source_summary cross join counts;
  if result is null then
    raise exception 'PACKAGE_CHANGE_TARGET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if result->>'fromPackageRevisionId' = result->>'toPackageRevisionId' then
    raise exception 'PACKAGE_CHANGE_TARGET_UNCHANGED' using errcode = '22023';
  end if;
  return result;
end;
$$;
revoke all on function private.package_change_state_v2(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.package_change_response_v2(
  p_request app.package_change_requests, p_reused boolean
)
returns jsonb language sql stable security definer
set search_path = app, private, pg_temp as $$
  select p_request.state_snapshot || jsonb_build_object(
    'requestId', p_request.id,
    'status', p_request.status,
    'revision', p_request.state_revision,
    'reused', p_reused,
    'result', p_request.result_snapshot
  );
$$;
revoke all on function private.package_change_response_v2(
  app.package_change_requests, boolean
) from public, anon, authenticated, service_role;

create or replace function app.preflight_package_change_v2(
  p_order_id uuid, p_target_revision_id uuid, p_reason text,
  p_request_id uuid, p_correlation_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = app, private, extensions, pg_temp as $$
declare actor uuid := private.require_admin_aal2();
  normalized_reason text := regexp_replace(btrim(coalesce(p_reason, '')), '[[:space:]]+', ' ', 'g');
  current_state jsonb; current_revision text; computed_hash text;
  existing app.package_change_requests%rowtype; inserted app.package_change_requests%rowtype;
begin
  if p_order_id is null or p_target_revision_id is null or p_request_id is null
    or length(normalized_reason) not between 4 and 480
  then raise exception 'PACKAGE_CHANGE_INPUT_INVALID' using errcode = '22023'; end if;
  computed_hash := encode(extensions.digest(jsonb_build_object(
    'version', 2, 'orderId', p_order_id,
    'targetRevisionId', p_target_revision_id, 'reason', normalized_reason
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('package-change-request:' || p_request_id::text, 0));
  select * into existing from app.package_change_requests where id = p_request_id for update;
  if found then
    if existing.requested_by <> actor or existing.request_hash <> computed_hash then
      raise exception 'PACKAGE_CHANGE_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.package_change_response_v2(existing, true);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('package-change-order:' || p_order_id::text, 0));
  perform 1 from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'PACKAGE_CHANGE_ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  current_state := private.package_change_state_v2(p_order_id, p_target_revision_id);
  current_revision := encode(extensions.digest(current_state::text, 'sha256'), 'hex');
  perform set_config('app.package_change_request_internal', 'on', true);
  update app.package_change_requests set status = 'superseded'
  where order_id = p_order_id and status in ('ready', 'blocked');
  perform set_config('app.package_change_request_internal', 'off', true);
  insert into app.package_change_requests(
    id, order_id, member_season_id, season_id, from_snapshot_id,
    from_package_revision_id, from_package_name, from_price_cents, from_currency,
    to_package_revision_id, to_package_name, to_price_cents, to_currency,
    price_delta_cents, state_snapshot, state_revision, reason, request_hash,
    status, requested_by, correlation_id
  ) values (
    p_request_id, p_order_id, (current_state->>'memberSeasonId')::uuid,
    (current_state->>'seasonId')::uuid, (current_state->>'fromSnapshotId')::uuid,
    nullif(current_state->>'fromPackageRevisionId', '')::uuid,
    current_state->>'fromPackageName', (current_state->>'fromPriceCents')::integer,
    current_state->>'fromCurrency', (current_state->>'toPackageRevisionId')::uuid,
    current_state->>'toPackageName', (current_state->>'toPriceCents')::integer,
    current_state->>'toCurrency', (current_state->>'priceDeltaCents')::integer,
    current_state, current_revision, normalized_reason, computed_hash,
    case when (current_state->>'canApply')::boolean then 'ready' else 'blocked' end,
    actor, p_correlation_id
  ) returning * into inserted;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'package_change.preflighted_v2', 'package_change_request', inserted.id,
    jsonb_build_object('orderId', inserted.order_id,
      'fromSnapshotId', inserted.from_snapshot_id,
      'toPackageRevisionId', inserted.to_package_revision_id,
      'creditAppliedCents', (current_state->>'creditAppliedCents')::integer,
      'additionalDueCents', (current_state->>'additionalDueCents')::integer,
      'refundDueCents', (current_state->>'refundDueCents')::integer,
      'status', inserted.status), p_correlation_id);
  return private.package_change_response_v2(inserted, false);
end;
$$;
revoke all on function app.preflight_package_change_v2(uuid, uuid, text, uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function app.preflight_package_change_v2(uuid, uuid, text, uuid, uuid)
to authenticated;

create or replace function app.apply_package_change_v2(
  p_request_id uuid, p_expected_revision text, p_confirmation text,
  p_correlation_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = app, private, extensions, pg_temp as $$
declare actor uuid := private.require_admin_aal2();
  target app.package_change_requests%rowtype; current_state jsonb;
  current_revision text; released_count integer := 0; next_snapshot uuid;
  v_adjustment_id uuid; confirmation_id uuid; confirmation_revision integer;
  materialization jsonb := jsonb_build_object('orderLinesMaterialized', 0, 'snapshotItemsLinked', 0);
  result jsonb; target_fully_covered boolean; inserted_size_count integer;
begin
  if p_request_id is null or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_confirmation not in ('SWITCH_PACKAGE', 'RELEASE_ALLOCATIONS_AND_SWITCH')
  then raise exception 'PACKAGE_CHANGE_APPLY_INVALID' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('package-change-order-request:' || p_request_id::text, 0));
  select * into target from app.package_change_requests where id = p_request_id for update;
  if not found then raise exception 'PACKAGE_CHANGE_REQUEST_NOT_FOUND' using errcode = 'P0002'; end if;
  if target.status = 'applied' then
    if target.state_revision <> p_expected_revision then
      raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
    end if;
    return private.package_change_response_v2(target, true);
  end if;
  if target.status not in ('ready', 'blocked') or target.state_revision <> p_expected_revision then
    raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('package-change-order:' || target.order_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('package-lifecycle:' || target.order_id::text, 0));
  perform 1 from app.member_orders where id = target.order_id for update;
  perform 1 from app.package_template_revisions revision
    where revision.id = target.to_package_revision_id
      and revision.season_id = target.season_id
      and revision.status = 'published' and revision.active for update;
  if not found then raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001'; end if;
  perform 1 from app.member_article_sizes profile
    join app.package_template_items item on item.article_id=profile.article_id
      and item.revision_id=target.to_package_revision_id
    where profile.member_season_id=target.member_season_id
    order by profile.article_id for update of profile;
  perform 1 from app.article_variants variant
    join app.package_template_items item on item.article_id=variant.article_id
      and item.revision_id=target.to_package_revision_id
    order by variant.id for update of variant;
  perform 1
  from app.package_refunds refund
  join app.package_financial_adjustments financial
    on financial.id = refund.adjustment_id
  where financial.order_id = target.order_id
  order by refund.id
  for update of refund;
  current_state := private.package_change_state_v2(target.order_id, target.to_package_revision_id);
  current_revision := encode(extensions.digest(current_state::text, 'sha256'), 'hex');
  if current_revision <> target.state_revision then
    raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
  end if;
  if (current_state->>'blockedByFulfilment')::boolean then
    raise exception 'PACKAGE_CHANGE_FULFILMENT_BLOCKED' using errcode = '23514';
  end if;
  if not (current_state->>'canApply')::boolean then
    raise exception 'PACKAGE_CHANGE_BLOCKED' using errcode = '23514';
  end if;
  if (current_state->>'requiresAllocationRelease')::boolean
    <> (p_confirmation = 'RELEASE_ALLOCATIONS_AND_SWITCH')
  then raise exception 'PACKAGE_CHANGE_CONFIRMATION_REQUIRED' using errcode = '22023'; end if;

  if (current_state->>'requiresAllocationRelease')::boolean then
    released_count := private.release_order_inventory_allocations(
      target.order_id, 'Pakketcorrectie: ' || target.reason, actor,
      'package_change_request', target.id, p_correlation_id
    );
  end if;
  perform set_config('app.package_size_internal', 'on', true);
  update app.order_lines set status = 'cancelled', updated_at = timezone('utc', now())
  where order_id = target.order_id and status = 'backorder';
  perform set_config('app.package_change_internal', 'on', true);
  update app.member_orders set package_revision_id = target.to_package_revision_id,
    amount_due_cents = target.to_price_cents
  where id = target.order_id returning active_package_snapshot_id into next_snapshot;
  perform set_config('app.package_change_internal', 'off', true);

  -- The snapshot ID is assigned by a BEFORE trigger even though it is not an
  -- explicit UPDATE target, so PostgreSQL does not fire the existing
  -- AFTER UPDATE OF active_package_snapshot_id trigger for this statement.
  -- Project the new immutable assignment in this same transaction before any
  -- assignment-scoped size selections are written.
  update app.member_package_assignments
  set status = 'historical', ended_at = coalesce(ended_at, timezone('utc', now()))
  where member_season_id = target.member_season_id
    and status = 'active' and id <> next_snapshot;
  insert into app.member_package_assignments(
    id, order_id, member_season_id, package_revision_id, status,
    assigned_at, ended_at, assignment_reason
  )
  select snapshot.id, target.order_id, target.member_season_id,
    snapshot.template_revision_id, 'active', snapshot.created_at, null,
    coalesce(nullif(btrim(snapshot.reason), ''), 'Pakketcorrectie door beheer')
  from app.order_package_snapshots snapshot where snapshot.id = next_snapshot
  on conflict (id) do update set status = 'active', ended_at = null;

  insert into app.package_financial_adjustments(
    package_change_request_id, order_id, member_season_id,
    from_package_snapshot_id, to_package_snapshot_id,
    from_package_revision_id, to_package_revision_id,
    original_paid_cents, applied_credit_cents, additional_due_cents,
    refund_due_cents, currency, status, created_by, reason, correlation_id
  ) values (
    target.id, target.order_id, target.member_season_id, target.from_snapshot_id,
    next_snapshot, target.from_package_revision_id, target.to_package_revision_id,
    (current_state->>'effectivePaidCents')::integer,
    (current_state->>'creditAppliedCents')::integer,
    (current_state->>'additionalDueCents')::integer,
    (current_state->>'refundDueCents')::integer,
    'EUR', 'applied', actor, target.reason, p_correlation_id
  ) returning id into v_adjustment_id;

  with prior_adjustment as (
    select adjustment.id from app.package_financial_adjustments adjustment
    where adjustment.to_package_snapshot_id = target.from_snapshot_id
      and adjustment.id <> v_adjustment_id
  ), sources as (
    select allocation.payment_id, allocation.amount_cents, payment.paid_at
    from prior_adjustment
    join app.package_credit_allocations allocation
      on allocation.adjustment_id = prior_adjustment.id
    join app.payments payment on payment.id = allocation.payment_id
    union all
    select payment.id, payment.amount_cents, payment.paid_at
    from app.payments payment
    where payment.order_id = target.order_id
      and payment.package_snapshot_id = target.from_snapshot_id
      and payment.status = 'paid' and payment.reconciliation_issue is null
  ), ranked as (
    select sources.*, coalesce(sum(amount_cents) over (
      order by paid_at, payment_id rows between unbounded preceding and 1 preceding
    ), 0)::integer prior_cents from sources
  )
  insert into app.package_credit_allocations(adjustment_id, payment_id, amount_cents, currency)
  select v_adjustment_id, payment_id,
    least(amount_cents, greatest((current_state->>'creditAppliedCents')::integer - prior_cents, 0)),
    'EUR'
  from ranked
  where least(amount_cents,
    greatest((current_state->>'creditAppliedCents')::integer - prior_cents, 0)) > 0;

  with prior_adjustment as (
    select adjustment.id from app.package_financial_adjustments adjustment
    where adjustment.to_package_snapshot_id = target.from_snapshot_id
      and adjustment.id <> v_adjustment_id
  ), sources as (
    select allocation.payment_id, allocation.amount_cents
    from prior_adjustment
    join app.package_credit_allocations allocation
      on allocation.adjustment_id = prior_adjustment.id
    union all
    select payment.id, payment.amount_cents from app.payments payment
    where payment.order_id = target.order_id
      and payment.package_snapshot_id = target.from_snapshot_id
      and payment.status = 'paid' and payment.reconciliation_issue is null
  )
  insert into app.package_refunds(
    adjustment_id, payment_id, order_id, method, amount_cents, currency, status,
    correlation_id
  )
  select v_adjustment_id, sources.payment_id, target.order_id, payment.method,
    sources.amount_cents - coalesce(credit.amount_cents, 0), 'EUR',
    case when payment.method = 'mollie' then 'due' else 'manual_due' end,
    p_correlation_id
  from sources join app.payments payment on payment.id = sources.payment_id
  left join app.package_credit_allocations credit
    on credit.adjustment_id = v_adjustment_id and credit.payment_id = sources.payment_id
  where sources.amount_cents - coalesce(credit.amount_cents, 0) > 0;

  if (select coalesce(sum(allocation.amount_cents), 0)
      from app.package_credit_allocations allocation
      where allocation.adjustment_id = (select financial.id
        from app.package_financial_adjustments financial
        where financial.package_change_request_id = target.id))
      <> (current_state->>'creditAppliedCents')::integer
    or (select coalesce(sum(refund.amount_cents), 0)
      from app.package_refunds refund
      where refund.adjustment_id = (select financial.id
        from app.package_financial_adjustments financial
        where financial.package_change_request_id = target.id))
      <> (current_state->>'refundDueCents')::integer
  then raise exception 'PACKAGE_FINANCIAL_LEDGER_MISMATCH' using errcode = '23514'; end if;

  if (current_state->>'targetPackageRequiredSizeCount')::integer > 0
    and (current_state->>'targetPackageMissingSizeCount')::integer = 0
  then
    select coalesce(max(confirmation.revision), 0) + 1 into confirmation_revision
    from app.package_size_confirmations confirmation where confirmation.order_id = target.order_id;
    insert into app.package_size_confirmations(
      order_id, member_season_id, revision, source, staff_user_id,
      selected_count, conflict_count, change_request_count, correlation_id,
      schema_version
    ) values (
      target.order_id, target.member_season_id, confirmation_revision, 'staff', actor,
      (current_state->>'targetPackageRequiredSizeCount')::integer, 0, 0,
      p_correlation_id, 2
    ) returning id into confirmation_id;
    insert into app.package_size_confirmation_items(
      confirmation_id, snapshot_item_id, article_id, selection_kind,
      selected_variant_id, other_note, quantity_snapshot,
      product_name_snapshot, product_code_snapshot, size_label_snapshot
    )
    select confirmation_id, item.id, item.article_id, 'variant',
      profile.article_variant_id, null, item.quantity,
      item.product_name_snapshot, item.product_code_snapshot, variant.size
    from app.order_package_snapshot_items item
    join app.member_article_sizes profile
      on profile.member_season_id = target.member_season_id
      and profile.article_id = item.article_id
      and profile.selection_status in ('confirmed', 'locked')
      and profile.confirmed_at is not null
    join app.article_variants variant on variant.id = profile.article_variant_id
      and variant.article_id = item.article_id and variant.active
    join app.article_seasons link on link.article_id = variant.article_id
      and link.season_id = target.season_id
    where item.snapshot_id = next_snapshot
    order by item.sort_order, item.id;
    get diagnostics inserted_size_count = row_count;
    if inserted_size_count <> (current_state->>'targetPackageRequiredSizeCount')::integer then
      raise exception 'PACKAGE_CHANGE_SIZE_STATE_CHANGED' using errcode = '40001';
    end if;
  end if;

  target_fully_covered := (current_state->>'additionalDueCents')::integer = 0;
  if target_fully_covered
    and private.package_variant_sizes_complete(target.order_id, next_snapshot)
  then
    materialization := private.ensure_package_size_lifecycle(target.order_id);
  end if;
  perform set_config('app.package_size_internal', 'off', true);
  perform app.refresh_order_status(target.order_id);

  result := jsonb_build_object(
    'requestId', target.id, 'adjustmentId', v_adjustment_id,
    'orderId', target.order_id, 'memberSeasonId', target.member_season_id,
    'fromSnapshotId', target.from_snapshot_id, 'toSnapshotId', next_snapshot,
    'toPackageRevisionId', target.to_package_revision_id,
    'priceDeltaCents', target.price_delta_cents,
    'creditAppliedCents', (current_state->>'creditAppliedCents')::integer,
    'additionalDueCents', (current_state->>'additionalDueCents')::integer,
    'refundDueCents', (current_state->>'refundDueCents')::integer,
    'releasedAllocationCount', released_count,
    'targetSizesConfirmed', private.package_variant_sizes_complete(target.order_id, next_snapshot),
    'materialization', materialization,
    'paymentTransferred', false,
    'refunds', coalesce((select jsonb_agg(jsonb_build_object(
      'refundId', refund.id, 'paymentId', refund.payment_id,
      'method', refund.method::text, 'amountCents', refund.amount_cents,
      'status', refund.status
    ) order by refund.created_at, refund.id)
      from app.package_refunds refund where refund.adjustment_id = v_adjustment_id), '[]'::jsonb),
    'status', 'applied'
  );
  perform set_config('app.package_change_request_internal', 'on', true);
  update app.package_change_requests set status = 'applied',
    applied_at = timezone('utc', now()), applied_by = actor, result_snapshot = result
  where id = target.id returning * into target;
  perform set_config('app.package_change_request_internal', 'off', true);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'package_change.applied_v2', 'package_financial_adjustment', v_adjustment_id,
    jsonb_build_object('orderId', target.order_id,
      'fromSnapshotId', target.from_snapshot_id, 'toSnapshotId', next_snapshot,
      'creditAppliedCents', (current_state->>'creditAppliedCents')::integer,
      'additionalDueCents', (current_state->>'additionalDueCents')::integer,
      'refundDueCents', (current_state->>'refundDueCents')::integer,
      'releasedAllocationCount', released_count,
      'targetSizesConfirmed', private.package_variant_sizes_complete(target.order_id, next_snapshot)),
    p_correlation_id);
  return private.package_change_response_v2(target, false);
end;
$$;
revoke all on function app.apply_package_change_v2(uuid, text, text, uuid)
from public, anon, authenticated, service_role;
grant execute on function app.apply_package_change_v2(uuid, text, text, uuid)
to authenticated;

create or replace function public.prepare_mollie_payment(
  p_token_hash text, p_order_id uuid, p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path = app, private, public, pg_temp as $$
declare target_order app.member_orders%rowtype; target_payment app.payments%rowtype;
  balance record; reused boolean := false; now_utc timestamptz := timezone('utc', now());
begin
  if p_token_hash !~ '^[0-9a-f]{64}$'
    or length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 160
  then raise exception 'INVALID_PAYMENT_REQUEST' using errcode = '22023'; end if;
  if private.parent_account_for_member_season(
    p_token_hash, (select member_season_id from app.member_orders where id = p_order_id)
  ) is null then raise exception 'PARENT_ORDER_ACCESS_DENIED' using errcode = '42501'; end if;
  select * into target_order from app.member_orders where id = p_order_id for update;
  if not found or target_order.package_assignment_state <> 'active' then
    raise exception 'ORDER_NOT_AVAILABLE' using errcode = 'P0002';
  end if;
  select * into balance from private.order_financial_balance(target_order.id);
  if balance.reconciliation_conflict_count > 0 then
    raise exception 'PAYMENT_RECONCILIATION_OPEN' using errcode = '23514';
  end if;
  if balance.remaining_due_cents = 0 then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23514';
  end if;
  if target_order.package_revision_id is not null
    and not exists(select 1 from app.payments payment
      where payment.idempotency_key = btrim(p_idempotency_key)
        and payment.order_id = target_order.id
        and payment.status in ('open', 'pending'))
  then perform private.ensure_package_size_lifecycle(target_order.id); end if;
  select * into target_payment from app.payments payment
  where payment.idempotency_key = btrim(p_idempotency_key) for update;
  if found then
    if target_payment.order_id <> target_order.id
      or target_payment.package_snapshot_id <> target_order.active_package_snapshot_id
      or target_payment.amount_cents <> balance.remaining_due_cents
      or target_payment.status not in ('open', 'pending')
    then raise exception 'PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    reused := true;
  else
    select * into target_payment from app.payments payment
    where payment.order_id = target_order.id and payment.method = 'mollie'
      and payment.package_snapshot_id = target_order.active_package_snapshot_id
      and payment.status in ('open', 'pending')
    order by payment.created_at desc limit 1 for update;
    if found then
      if target_payment.amount_cents <> balance.remaining_due_cents
        or (target_payment.provider_payment_id is null
          and target_payment.created_at + interval '1 hour' <= now_utc)
        or (target_payment.provider_payment_id is not null
          and (target_payment.checkout_url is null
            or target_payment.provider_expires_at <= now_utc))
      then raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514'; end if;
      reused := true;
    else
      insert into app.payments(order_id, method, status, amount_cents, currency,
        idempotency_key, metadata_schema_version)
      values(target_order.id, 'mollie', 'open', balance.remaining_due_cents,
        'EUR', btrim(p_idempotency_key), 2) returning * into target_payment;
    end if;
  end if;
  return jsonb_build_object(
    'paymentId', target_payment.id, 'orderId', target_order.id,
    'amountCents', target_payment.amount_cents, 'currency', 'EUR',
    'status', target_payment.status::text,
    'providerPaymentId', target_payment.provider_payment_id,
    'checkoutUrl', target_payment.checkout_url, 'reused', reused,
    'idempotencyKey', target_payment.idempotency_key,
    'metadata', jsonb_build_object(
      'payment_id', target_payment.id, 'order_id', target_order.id,
      'member_id', target_order.member_id,
      'member_season_id', target_order.member_season_id,
      'season_id', target_order.season_id, 'schema_version', 2
    )
  );
end;
$$;
revoke all on function public.prepare_mollie_payment(text, uuid, text)
from public, anon, authenticated, service_role;
grant execute on function public.prepare_mollie_payment(text, uuid, text) to service_role;

create or replace function app.record_manual_payment_v2(
  p_order_id uuid, p_method app.payment_method, p_amount_cents integer,
  p_reason text, p_request_id uuid, p_correlation_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = app, private, extensions, pg_temp as $$
declare actor uuid := private.require_admin_aal2(); target_order app.member_orders%rowtype;
  existing private.manual_payment_requests%rowtype; normalized_reason text;
  computed_hash text; payment_id uuid; balance record; result jsonb; card_enabled boolean;
begin
  normalized_reason := regexp_replace(btrim(coalesce(p_reason, '')), '[[:space:]]+', ' ', 'g');
  if p_order_id is null or p_request_id is null or p_method not in ('cash', 'card')
    or p_amount_cents <= 0 or length(normalized_reason) not between 4 and 500
  then raise exception 'INVALID_MANUAL_PAYMENT' using errcode = '22023'; end if;
  select enabled into card_enabled from app.release_feature_flags where key = 'legacy_card_payment';
  if p_method = 'card' and not coalesce(card_enabled, false) then
    raise exception 'LEGACY_CARD_PAYMENT_DISABLED' using errcode = '55000';
  end if;
  computed_hash := encode(extensions.digest(jsonb_build_object(
    'orderId', p_order_id, 'method', p_method::text,
    'amountCents', p_amount_cents, 'reason', normalized_reason
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('manual-payment-request:' || p_request_id::text, 0));
  select * into target_order from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_AVAILABLE' using errcode = 'P0002'; end if;
  select * into existing from private.manual_payment_requests where request_id = p_request_id;
  if found then
    if existing.order_id <> p_order_id or existing.actor_user_id <> actor
      or existing.request_hash <> computed_hash
    then raise exception 'MANUAL_PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;
  select * into balance from private.order_financial_balance(target_order.id);
  if balance.reconciliation_conflict_count > 0 then
    raise exception 'PAYMENT_RECONCILIATION_OPEN' using errcode = '23514';
  end if;
  if balance.remaining_due_cents = 0 then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23505';
  end if;
  if p_amount_cents <> balance.remaining_due_cents then
    raise exception 'MANUAL_PAYMENT_AMOUNT_MISMATCH' using errcode = '23514';
  end if;
  if target_order.package_revision_id is not null then
    perform private.ensure_package_size_lifecycle(target_order.id);
  end if;
  if exists(select 1 from app.payments payment where payment.order_id = target_order.id
    and payment.method = 'mollie' and payment.status in ('open', 'pending'))
  then raise exception 'MOLLIE_ATTEMPT_ACTIVE' using errcode = '23514'; end if;
  insert into app.payments(order_id, method, status, amount_cents, currency,
    idempotency_key, paid_at, manual_request_id, manual_reason, recorded_by)
  values(target_order.id, p_method, 'paid', balance.remaining_due_cents, 'EUR',
    'manual:v2:' || p_request_id::text, timezone('utc', now()), p_request_id,
    normalized_reason, actor) returning id into payment_id;
  result := jsonb_build_object('paymentId', payment_id, 'orderId', target_order.id,
    'memberSeasonId', target_order.member_season_id, 'seasonId', target_order.season_id,
    'status', 'paid', 'amountCents', balance.remaining_due_cents,
    'currency', 'EUR', 'method', p_method::text,
    'qrStatus', 'inactive_until_allocated', 'reused', false);
  insert into private.manual_payment_requests(request_id, order_id, payment_id,
    actor_user_id, method, amount_cents, reason, request_hash, result_snapshot)
  values(p_request_id, target_order.id, payment_id, actor, p_method,
    balance.remaining_due_cents, normalized_reason, computed_hash, result);
  perform private.enqueue_order_email(target_order.id, 'payment_received',
    'transaction:payment_received:' || payment_id::text);
  perform app.refresh_order_status(target_order.id);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'payment.manual.recorded_v2', 'member_order', target_order.id,
    jsonb_build_object('payment_id', payment_id, 'manual_request_id', p_request_id,
      'method', p_method::text, 'amount_cents', balance.remaining_due_cents,
      'currency', 'EUR',
      'reason_sha256', encode(extensions.digest(convert_to(normalized_reason, 'UTF8'), 'sha256'), 'hex'),
      'reason_recorded', true, 'qr_activated', false), p_correlation_id);
  return result;
end;
$$;
revoke all on function app.record_manual_payment_v2(
  uuid, app.payment_method, integer, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.record_manual_payment_v2(
  uuid, app.payment_method, integer, text, uuid, uuid
) to authenticated;

-- Refund execution is a durable, provider-idempotent state machine. Preparing
-- never marks money as returned; only an authoritative provider observation
-- may complete a Mollie obligation.
create or replace function app.prepare_mollie_refund_v1(
  p_refund_id uuid, p_operation_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare target app.package_refunds%rowtype; payment app.payments%rowtype;
  operation_key text; already_reserved integer;
begin
  if p_refund_id is null or p_operation_request_id is null then
    raise exception 'INVALID_MOLLIE_REFUND_REQUEST' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('package-refund:' || p_refund_id::text, 0));
  select * into target from app.package_refunds where id = p_refund_id for update;
  if not found then raise exception 'PACKAGE_REFUND_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into payment from app.payments where id = target.payment_id for update;
  if payment.method <> 'mollie' or payment.status <> 'paid'
    or payment.reconciliation_issue is not null
    or payment.provider_payment_id is null
  then raise exception 'MOLLIE_REFUND_NOT_ALLOWED' using errcode = '23514'; end if;
  if target.method <> 'mollie' then
    raise exception 'MOLLIE_REFUND_NOT_ALLOWED' using errcode = '23514';
  end if;
  if target.operation_request_id is not null then
    if target.operation_request_id <> p_operation_request_id then
      raise exception 'MOLLIE_REFUND_ALREADY_REQUESTED' using errcode = '23505';
    end if;
    if target.status = 'failed' and target.retryable then
      perform set_config('app.package_refund_internal', 'on', true);
      update app.package_refunds set status='requesting',requested_at=timezone('utc',now()),
        failed_at=null,failure_code=null,retryable=false
      where id=target.id returning * into target;
      perform set_config('app.package_refund_internal', 'off', true);
    end if;
    return jsonb_build_object(
      'refundId', target.id, 'paymentId', target.payment_id,
      'providerPaymentId', payment.provider_payment_id,
      'providerRefundId', target.provider_refund_id,
      'amountCents', target.amount_cents, 'currency', target.currency,
      'status', target.status, 'idempotencyKey', target.idempotency_key,
      'reused', target.status <> 'requesting'
    );
  end if;
  if target.status not in ('due', 'failed') or (target.status = 'failed' and not target.retryable) then
    raise exception 'MOLLIE_REFUND_NOT_RETRYABLE' using errcode = '23514';
  end if;
  select coalesce(sum(refund.amount_cents), 0)::integer into already_reserved
  from app.package_refunds refund
  where refund.payment_id = payment.id and refund.id <> target.id
    and refund.status not in ('failed', 'canceled', 'reconciliation_required');
  if already_reserved + target.amount_cents > payment.amount_cents then
    raise exception 'MOLLIE_REFUND_AMOUNT_EXCEEDS_PAYMENT' using errcode = '23514';
  end if;
  operation_key := 'package-refund:' || target.id::text;
  perform set_config('app.package_refund_internal', 'on', true);
  update app.package_refunds set status = 'requesting',
    operation_request_id = p_operation_request_id,
    idempotency_key = operation_key, requested_at = timezone('utc', now()),
    failure_code = null, retryable = false,
    correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = target.id returning * into target;
  perform set_config('app.package_refund_internal', 'off', true);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(null, 'payment.mollie.refund_requested', 'package_refund', target.id,
    jsonb_build_object('payment_id', target.payment_id,
      'adjustment_id', target.adjustment_id, 'amount_cents', target.amount_cents,
      'currency', target.currency), p_correlation_id);
  return jsonb_build_object(
    'refundId', target.id, 'paymentId', target.payment_id,
    'providerPaymentId', payment.provider_payment_id,
    'providerRefundId', null, 'amountCents', target.amount_cents,
    'currency', target.currency, 'status', target.status,
    'idempotencyKey', target.idempotency_key, 'reused', false
  );
end;
$$;

create or replace function app.bind_mollie_refund_v1(
  p_refund_id uuid, p_provider_refund_id text, p_provider_status text,
  p_observed_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare target app.package_refunds%rowtype; local_status text;
begin
  if p_refund_id is null or p_provider_refund_id !~ '^re_[A-Za-z0-9]+$'
    or p_provider_status not in ('queued','pending','processing','refunded','failed','canceled')
    or p_observed_at is null
  then raise exception 'INVALID_MOLLIE_REFUND_BINDING' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('package-refund:' || p_refund_id::text, 0));
  select * into target from app.package_refunds where id = p_refund_id for update;
  if not found then raise exception 'PACKAGE_REFUND_NOT_FOUND' using errcode = 'P0002'; end if;
  if target.method <> 'mollie' or target.status <> 'requesting'
    or (target.provider_refund_id is not null and target.provider_refund_id <> p_provider_refund_id)
  then raise exception 'MOLLIE_REFUND_BINDING_CONFLICT' using errcode = '23514'; end if;
  local_status := case p_provider_status
    when 'refunded' then 'completed' else p_provider_status end;
  perform set_config('app.package_refund_internal', 'on', true);
  update app.package_refunds set provider_refund_id = p_provider_refund_id,
    provider_status = p_provider_status, status = local_status,
    provider_accepted_at = p_observed_at, reconciled_at = p_observed_at,
    completed_at = case when p_provider_status = 'refunded' then p_observed_at else null end,
    failed_at = case when p_provider_status in ('failed','canceled') then p_observed_at else null end,
    retryable = p_provider_status = 'failed',
    failure_code = case when p_provider_status = 'failed' then 'MOLLIE_REFUND_FAILED' else null end
  where id = target.id returning * into target;
  perform set_config('app.package_refund_internal', 'off', true);
  insert into private.package_refund_events(refund_id,provider_refund_id,provider_status,
    amount_cents,currency,event_key,observation)
  values(target.id,p_provider_refund_id,p_provider_status,target.amount_cents,target.currency,
    'mollie-refund:'||p_provider_refund_id||':'||p_provider_status,
    jsonb_build_object('status',p_provider_status)) on conflict(event_key) do nothing;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(null, 'payment.mollie.refund_provider_accepted', 'package_refund', target.id,
    jsonb_build_object('provider_refund_id', p_provider_refund_id,
      'provider_status', p_provider_status, 'amount_cents', target.amount_cents),
    target.correlation_id);
  return jsonb_build_object('refundId', target.id,
    'providerRefundId', target.provider_refund_id, 'status', target.status,
    'providerStatus', target.provider_status, 'amountCents', target.amount_cents,
    'currency', target.currency);
end;
$$;

create or replace function app.fail_mollie_refund_v1(
  p_refund_id uuid, p_failure_code text, p_retryable boolean,
  p_observed_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare target app.package_refunds%rowtype;
begin
  if p_refund_id is null or p_failure_code !~ '^[A-Z][A-Z0-9_]{2,79}$'
    or p_observed_at is null then
    raise exception 'INVALID_MOLLIE_REFUND_FAILURE' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('package-refund:' || p_refund_id::text, 0));
  select * into target from app.package_refunds where id = p_refund_id for update;
  if not found then raise exception 'PACKAGE_REFUND_NOT_FOUND' using errcode = 'P0002'; end if;
  if target.status in ('completed','manual_completed') then
    return jsonb_build_object('refundId', target.id, 'status', target.status, 'reused', true);
  end if;
  perform set_config('app.package_refund_internal', 'on', true);
  update app.package_refunds set status = 'failed', failed_at = p_observed_at,
    failure_code = p_failure_code, retryable = coalesce(p_retryable, false),
    reconciled_at = p_observed_at
  where id = target.id returning * into target;
  perform set_config('app.package_refund_internal', 'off', true);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(null, 'payment.mollie.refund_failed', 'package_refund', target.id,
    jsonb_build_object('failure_code', p_failure_code,
      'retryable', coalesce(p_retryable, false)), target.correlation_id);
  return jsonb_build_object('refundId', target.id, 'status', target.status,
    'retryable', target.retryable);
end;
$$;

create or replace function app.reconcile_mollie_refunds_v1(
  p_provider_payment_id text, p_refunds jsonb, p_observed_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare payment app.payments%rowtype; target app.package_refunds%rowtype;
  provider jsonb; v_provider_status text; v_provider_amount integer;
  updated_count integer := 0;
begin
  if p_provider_payment_id !~ '^tr_[A-Za-z0-9]+$'
    or jsonb_typeof(p_refunds) <> 'array' or jsonb_array_length(p_refunds) > 250
    or p_observed_at is null
  then raise exception 'INVALID_MOLLIE_REFUND_OBSERVATION' using errcode = '22023'; end if;
  select * into payment from app.payments
  where provider_payment_id = p_provider_payment_id for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002'; end if;
  for target in select refund.* from app.package_refunds refund
    where refund.payment_id = payment.id and refund.provider_refund_id is not null
    order by refund.created_at, refund.id for update
  loop
    select value into provider from jsonb_array_elements(p_refunds) item(value)
    where value->>'id' = target.provider_refund_id limit 1;
    if provider is null then continue; end if;
    v_provider_status := provider->>'status';
    if v_provider_status not in ('queued','pending','processing','refunded','failed','canceled')
      or provider#>>'{amount,currency}' <> 'EUR'
      or (provider#>>'{amount,value}') !~ '^\d+\.\d{2}$'
    then
      v_provider_status := null;
    else
      v_provider_amount := split_part(provider#>>'{amount,value}', '.', 1)::integer * 100
        + split_part(provider#>>'{amount,value}', '.', 2)::integer;
    end if;
    perform set_config('app.package_refund_internal', 'on', true);
    if v_provider_status is null or v_provider_amount <> target.amount_cents then
      update app.package_refunds set status = 'reconciliation_required',
        reconciled_at = p_observed_at, failure_code = 'MOLLIE_REFUND_MISMATCH', retryable = false
      where id = target.id;
    else
      update app.package_refunds set provider_status = v_provider_status,
        status = case when v_provider_status = 'refunded' then 'completed' else v_provider_status end,
        reconciled_at = p_observed_at,
        completed_at = case when v_provider_status = 'refunded'
          then coalesce(completed_at, p_observed_at) else completed_at end,
        failed_at = case when v_provider_status in ('failed','canceled')
          then coalesce(failed_at, p_observed_at) else null end,
        failure_code = case when v_provider_status = 'failed' then 'MOLLIE_REFUND_FAILED' else null end,
        retryable = v_provider_status = 'failed'
      where id = target.id;
    end if;
    perform set_config('app.package_refund_internal', 'off', true);
    insert into private.package_refund_events(refund_id,provider_refund_id,provider_status,
      amount_cents,currency,event_key,observation)
    values(target.id,target.provider_refund_id,coalesce(v_provider_status,'mismatch'),
      target.amount_cents,target.currency,
      'mollie-refund:'||target.provider_refund_id||':'||coalesce(v_provider_status,'mismatch')||':'||target.amount_cents,
      jsonb_build_object('status',coalesce(v_provider_status,'mismatch')))
    on conflict(event_key) do nothing;
    updated_count := updated_count + 1;
  end loop;
  perform app.refresh_order_status(payment.order_id);
  return jsonb_build_object('paymentId', payment.id, 'orderId', payment.order_id,
    'updatedCount', updated_count);
end;
$$;

revoke all on function app.prepare_mollie_refund_v1(uuid, uuid, uuid),
  app.bind_mollie_refund_v1(uuid, text, text, timestamptz),
  app.fail_mollie_refund_v1(uuid, text, boolean, timestamptz),
  app.reconcile_mollie_refunds_v1(text, jsonb, timestamptz)
from public, anon, authenticated, service_role;
grant execute on function app.prepare_mollie_refund_v1(uuid, uuid, uuid),
  app.bind_mollie_refund_v1(uuid, text, text, timestamptz),
  app.fail_mollie_refund_v1(uuid, text, boolean, timestamptz),
  app.reconcile_mollie_refunds_v1(text, jsonb, timestamptz)
to service_role;

create or replace function app.record_manual_payment_refund_v2(
  p_refund_id uuid, p_payment_id uuid, p_amount_cents integer,
  p_reason text, p_evidence_reference text, p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = app, private, extensions, pg_temp as $$
declare actor uuid := private.require_admin_aal2(); target app.package_refunds%rowtype;
  normalized_reason text; normalized_evidence text; request_hash text;
  existing private.manual_payment_corrections%rowtype; result jsonb;
  v_completed_at timestamptz := timezone('utc', now());
begin
  normalized_reason := regexp_replace(btrim(coalesce(p_reason,'')), '[[:space:]]+', ' ', 'g');
  normalized_evidence := regexp_replace(btrim(coalesce(p_evidence_reference,'')), '[[:space:]]+', ' ', 'g');
  if p_refund_id is null or p_payment_id is null or p_request_id is null
    or p_amount_cents <= 0 or length(normalized_reason) not between 4 and 500
    or length(normalized_evidence) not between 4 and 160
  then raise exception 'INVALID_MANUAL_PAYMENT_REFUND' using errcode = '22023'; end if;
  request_hash := encode(extensions.digest(jsonb_build_object(
    'refundId', p_refund_id, 'paymentId', p_payment_id,
    'amountCents', p_amount_cents, 'reason', normalized_reason,
    'evidenceReference', normalized_evidence
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('manual-payment-refund:' || p_request_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('package-refund:' || p_refund_id::text, 0));
  select * into existing from private.manual_payment_corrections where request_id = p_request_id;
  if found then
    if existing.payment_id <> p_payment_id or existing.request_hash <> request_hash
      or existing.actor_user_id <> actor
    then raise exception 'MANUAL_PAYMENT_REFUND_IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;
  select * into target from app.package_refunds where id = p_refund_id for update;
  if not found or target.payment_id <> p_payment_id then
    raise exception 'MANUAL_PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.method not in ('cash','card') or target.status <> 'manual_due'
    or target.amount_cents <> p_amount_cents
  then raise exception 'MANUAL_PAYMENT_REFUND_NOT_ALLOWED' using errcode = '23514'; end if;
  perform set_config('app.package_refund_internal', 'on', true);
  update app.package_refunds set status = 'manual_completed',
    operation_request_id = p_request_id, completed_at = v_completed_at,
    reconciled_at = v_completed_at, manual_reason = normalized_reason,
    manual_evidence_reference = normalized_evidence, completed_by = actor,
    correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = target.id returning * into target;
  perform set_config('app.package_refund_internal', 'off', true);
  result := jsonb_build_object('requestId', p_request_id, 'refundId', target.id,
    'paymentId', target.payment_id, 'orderId', target.order_id,
    'status', 'manual_completed', 'method', target.method::text,
    'amountCents', target.amount_cents, 'currency', target.currency,
    'refundedAt', v_completed_at, 'releasedAllocationCount', 0,
    'qrRevoked', false, 'refundCreated', false,
    'refundExternallyConfirmed', true, 'reused', false);
  insert into private.manual_payment_corrections(request_id, payment_id, order_id,
    member_season_id, package_snapshot_id, actor_user_id, method, amount_cents,
    currency, reason, evidence_reference, request_hash, result_snapshot)
  select p_request_id, target.payment_id, target.order_id, orders.member_season_id,
    orders.active_package_snapshot_id, actor, target.method, target.amount_cents,
    target.currency, normalized_reason, normalized_evidence, request_hash, result
  from app.member_orders orders where orders.id = target.order_id;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'payment.manual.package_refund_recorded', 'package_refund', target.id,
    jsonb_build_object('payment_id', target.payment_id,
      'adjustment_id', target.adjustment_id, 'amount_cents', target.amount_cents,
      'currency', target.currency, 'evidence_recorded', true), p_correlation_id);
  return result;
end;
$$;
revoke all on function app.record_manual_payment_refund_v2(
  uuid, uuid, integer, text, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.record_manual_payment_refund_v2(
  uuid, uuid, integer, text, text, uuid, uuid
) to authenticated;

create table private.package_refund_events (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references app.package_refunds(id) on delete restrict,
  provider_refund_id text,
  provider_status text,
  amount_cents integer not null check (amount_cents > 0),
  currency text not null check (currency = 'EUR'),
  event_key text not null unique check (length(event_key) between 8 and 240),
  observation jsonb not null default '{}'::jsonb check (
    jsonb_typeof(observation) = 'object'
    and not (observation ?| array['email','name','token','checkout_url','api_key'])
  ),
  processed_at timestamptz not null default timezone('utc', now())
);
create index package_refund_events_refund_idx
  on private.package_refund_events(refund_id, processed_at desc);
alter table private.package_refund_events enable row level security;
revoke all on table private.package_refund_events
from public, anon, authenticated, service_role;

alter table app.package_refunds
  add constraint package_refunds_provider_id_format check (
    provider_refund_id is null or provider_refund_id ~ '^re_[A-Za-z0-9]+$'
  ),
  add constraint package_refunds_idempotency_format check (
    idempotency_key is null or length(idempotency_key) between 8 and 160
  );

create or replace function app.reconcile_mollie_payment_v3(
  p_event_key text, p_provider_id text, p_local_payment_id uuid,
  p_metadata_payment_id uuid, p_order_id uuid, p_member_id uuid,
  p_member_season_id uuid, p_season_id uuid, p_amount_cents integer,
  p_currency text, p_status app.payment_status,
  p_provider_created_at timestamptz, p_provider_updated_at timestamptz,
  p_provider_expires_at timestamptz, p_paid_at timestamptz,
  p_refunded_at timestamptz, p_validation_issue text default null,
  p_observation jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare target_payment app.payments%rowtype; target_order app.member_orders%rowtype;
  existing private.payment_events%rowtype; issue text; effect text := 'updated';
  resulting app.payment_status; event_type text; balance record; safe jsonb;
begin
  if length(btrim(coalesce(p_event_key,''))) not between 8 and 240
    or p_provider_id !~ '^tr_[A-Za-z0-9]+$' or p_local_payment_id is null
    or p_provider_updated_at is null or p_status = 'duplicate_paid'
    or jsonb_typeof(coalesce(p_observation,'{}'::jsonb)) <> 'object'
  then raise exception 'INVALID_MOLLIE_RECONCILIATION' using errcode = '22023'; end if;
  select * into existing from private.payment_events where idempotency_key = btrim(p_event_key);
  if found then return jsonb_build_object('paymentId', existing.payment_id,
    'status','replay','effect','event_replay','eventType',existing.event_type); end if;
  select * into target_payment from app.payments
  where id = p_local_payment_id and provider_payment_id = btrim(p_provider_id) for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into target_order from app.member_orders
  where id = target_payment.order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into existing from private.payment_events where idempotency_key = btrim(p_event_key);
  if found then return jsonb_build_object('paymentId', existing.payment_id,
    'status','replay','effect','event_replay','eventType',existing.event_type); end if;
  issue := case
    when p_validation_issue is not null then p_validation_issue
    when p_metadata_payment_id is null then 'MOLLIE_METADATA_MISSING'
    when p_metadata_payment_id <> target_payment.id then 'MOLLIE_METADATA_PAYMENT_MISMATCH'
    when target_payment.metadata_schema_version is null
      or not (p_observation->>'schema_version') ~ '^[0-9]+$'
      or (p_observation->>'schema_version')::integer <> target_payment.metadata_schema_version
      then 'MOLLIE_METADATA_SCHEMA_MISMATCH'
    when p_order_id <> target_order.id or p_member_id <> target_order.member_id
      or p_member_season_id <> target_order.member_season_id
      or p_season_id <> target_order.season_id then 'PAYMENT_METADATA_MISMATCH'
    when target_payment.package_snapshot_id <> target_order.active_package_snapshot_id
      then 'PAYMENT_PACKAGE_SNAPSHOT_MISMATCH'
    when target_payment.method <> 'mollie'
      or target_payment.amount_cents <> p_amount_cents or p_currency <> 'EUR'
      or target_payment.currency <> 'EUR' then 'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH'
    else null end;
  if issue is null and p_status = 'paid' and target_payment.status <> 'paid' then
    select * into balance from private.order_financial_balance(target_order.id);
    if balance.reconciliation_conflict_count > 0
      or balance.remaining_due_cents <> target_payment.amount_cents
    then issue := 'PAYMENT_ACTIVE_BALANCE_MISMATCH'; end if;
  end if;
  safe := jsonb_strip_nulls(jsonb_build_object('provider_id',btrim(p_provider_id),
    'status',p_status::text,'amount_cents',p_amount_cents,'currency',p_currency,
    'provider_created_at',p_provider_created_at,'provider_updated_at',p_provider_updated_at,
    'provider_expires_at',p_provider_expires_at,
    'schema_version',case when (p_observation->>'schema_version') ~ '^[0-9]+$'
      then (p_observation->>'schema_version')::integer else null end));
  if issue is not null then
    update app.payments set reconciliation_issue = left(issue,500),
      reconciled_at = timezone('utc',now()) where id = target_payment.id;
    insert into private.payment_events(payment_id,event_type,provider_payload_redacted,idempotency_key)
    values(target_payment.id,'mismatch',safe || jsonb_build_object('issue',issue),btrim(p_event_key));
    insert into app.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
    values(null,'payment.mollie.manual_review','payment',target_payment.id,
      jsonb_build_object('issue',issue,'provider_status',p_status::text));
    return jsonb_build_object('paymentId',target_payment.id,'status','manual_review',
      'effect','mismatch','issue',issue);
  end if;
  if target_payment.provider_updated_at is not null
    and p_provider_updated_at < target_payment.provider_updated_at then effect := 'stale_ignored';
  elsif p_status = 'paid' then
    if target_payment.status = 'paid' then effect := 'already_processed';
    elsif target_payment.status = 'refunded' then effect := 'terminal_ignored';
    elsif exists(select 1 from app.payments payment
      where payment.order_id = target_order.id
        and payment.package_snapshot_id = target_order.active_package_snapshot_id
        and payment.status = 'paid' and payment.id <> target_payment.id) then
      update app.payments set status='duplicate_paid',
        paid_at=coalesce(paid_at,p_paid_at,p_provider_updated_at),
        provider_updated_at=p_provider_updated_at,reconciled_at=timezone('utc',now()),
        reconciliation_issue='duplicate paid payment; manual reconciliation required'
      where id=target_payment.id; effect := 'duplicate_paid';
    else
      update app.payments set status='paid',paid_at=coalesce(paid_at,p_paid_at,p_provider_updated_at),
        provider_created_at=coalesce(provider_created_at,p_provider_created_at),
        provider_updated_at=p_provider_updated_at,provider_expires_at=p_provider_expires_at,
        reconciled_at=timezone('utc',now()),reconciliation_issue=null
      where id=target_payment.id;
      perform private.enqueue_order_email(target_order.id,'payment_received',
        'transaction:payment_received:' || target_payment.id::text);
      effect := 'paid';
    end if;
  elsif p_status = 'refunded' then
    if target_payment.status = 'refunded' then effect := 'already_processed';
    else
      update app.payments set status='refunded',
        refunded_at=coalesce(refunded_at,p_refunded_at,p_provider_updated_at),
        provider_updated_at=p_provider_updated_at,reconciled_at=timezone('utc',now())
      where id=target_payment.id; effect := 'refunded';
    end if;
  elsif target_payment.status in ('paid','refunded') then effect := 'terminal_ignored';
  else
    update app.payments set status=p_status,
      provider_created_at=coalesce(provider_created_at,p_provider_created_at),
      provider_updated_at=p_provider_updated_at,provider_expires_at=p_provider_expires_at,
      reconciled_at=timezone('utc',now()) where id=target_payment.id;
  end if;
  if effect in ('already_processed','terminal_ignored') then
    update app.payments set provider_updated_at=greatest(coalesce(provider_updated_at,p_provider_updated_at),p_provider_updated_at),
      reconciled_at=timezone('utc',now()) where id=target_payment.id;
  end if;
  perform app.refresh_order_status(target_order.id);
  select status into resulting from app.payments where id=target_payment.id;
  event_type := case effect when 'paid' then 'paid' when 'duplicate_paid' then 'duplicate_paid'
    when 'refunded' then 'refunded' when 'stale_ignored' then 'stale_ignored'
    when 'terminal_ignored' then 'terminal_ignored' when 'already_processed' then 'replay'
    else 'observed' end;
  insert into private.payment_events(payment_id,event_type,provider_payload_redacted,idempotency_key)
  values(target_payment.id,event_type,safe,btrim(p_event_key));
  return jsonb_build_object('paymentId',target_payment.id,'orderId',target_order.id,
    'memberSeasonId',target_order.member_season_id,'status',resulting::text,
    'effect',effect,'qrStatus',case when private.order_qr_business_eligible(target_order.id)
      then 'active' else 'inactive' end,'eventType',event_type);
end;
$$;
revoke all on function app.reconcile_mollie_payment_v3(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,integer,text,app.payment_status,
  timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,text,jsonb
) from public, anon, authenticated, service_role;
grant execute on function app.reconcile_mollie_payment_v3(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,integer,text,app.payment_status,
  timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,text,jsonb
) to service_role;

create or replace function private.order_financial_balance(p_order_id uuid)
returns table(
  active_package_price_cents integer, adjustment_id uuid,
  applied_credit_cents integer, successful_payment_cents integer,
  remaining_due_cents integer, refund_due_cents integer,
  refund_completed_cents integer, refund_outstanding_cents integer,
  reconciliation_conflict_count integer, effective_status text,
  settled_at timestamptz
)
language sql stable security definer
set search_path = app, private, pg_temp as $$
  with target as (
    select orders.id, orders.active_package_snapshot_id,
      coalesce(snapshot.package_price_cents,orders.amount_due_cents) active_price
    from app.member_orders orders
    left join app.order_package_snapshots snapshot
      on snapshot.id=orders.active_package_snapshot_id and snapshot.order_id=orders.id
    where orders.id=p_order_id
  ), adjustment as (
    select financial.* from target
    left join app.package_financial_adjustments financial
      on financial.to_package_snapshot_id=target.active_package_snapshot_id
  ), credit as (
    select coalesce(sum(allocation.amount_cents),0)::integer ledger_credit,
      count(*) filter(where payment.status <> 'paid'
        or payment.reconciliation_issue is not null)::integer unhealthy_sources
    from adjustment
    left join app.package_credit_allocations allocation
      on allocation.adjustment_id=adjustment.id
    left join app.payments payment on payment.id=allocation.payment_id
  ), active_payments as (
    select coalesce(sum(payment.amount_cents) filter(where payment.status='paid'
        and payment.reconciliation_issue is null),0)::integer paid_cents,
      max(payment.paid_at) filter(where payment.status='paid'
        and payment.reconciliation_issue is null) paid_at,
      count(*) filter(where payment.status='duplicate_paid'
        or payment.reconciliation_issue is not null)::integer conflicts,
      bool_or(payment.status='pending') pending_payment,
      bool_or(payment.status='open') open_payment,
      bool_or(payment.status='refunded') refunded_payment
    from target left join app.payments payment on payment.order_id=target.id
      and (target.active_package_snapshot_id is null
        or payment.package_snapshot_id=target.active_package_snapshot_id)
  ), refunds as (
    select coalesce(sum(refund.amount_cents),0)::integer due,
      coalesce(sum(refund.amount_cents) filter(where refund.status in
        ('completed','manual_completed')),0)::integer completed,
      count(*) filter(where refund.status='reconciliation_required')::integer conflicts
    from adjustment left join app.package_refunds refund on refund.adjustment_id=adjustment.id
  ), calculated as (
    select target.active_price,adjustment.id,
      coalesce(adjustment.applied_credit_cents,0)::integer declared_credit,
      credit.ledger_credit,active_payments.paid_cents,
      greatest(target.active_price-coalesce(adjustment.applied_credit_cents,0)
        -active_payments.paid_cents,0)::integer remaining,
      coalesce(adjustment.refund_due_cents,0)::integer declared_refund,
      refunds.due,refunds.completed,
      active_payments.conflicts+credit.unhealthy_sources+refunds.conflicts
        +case when coalesce(adjustment.applied_credit_cents,0)<>credit.ledger_credit then 1 else 0 end
        +case when coalesce(adjustment.refund_due_cents,0)<>refunds.due then 1 else 0 end conflicts,
      active_payments.pending_payment,active_payments.open_payment,
      active_payments.refunded_payment,
      greatest(adjustment.created_at,active_payments.paid_at) settled_at
    from target cross join active_payments cross join refunds cross join credit
    left join adjustment on true
  )
  select active_price,id,declared_credit,paid_cents,remaining,
    declared_refund,completed,greatest(declared_refund-completed,0)::integer,
    conflicts,case when conflicts>0 then 'reconciliation_required'
      when remaining=0 then 'paid' when pending_payment then 'pending'
      when open_payment then 'open' when refunded_payment then 'refunded' else 'open' end,
    case when remaining=0 then settled_at else null end
  from calculated;
$$;
revoke all on function private.order_financial_balance(uuid)
from public, anon, authenticated, service_role;

create or replace function app.refresh_order_status(p_order_id uuid)
returns text language plpgsql set search_path=app,private,pg_temp as $$
declare next_status text; balance record; q jsonb; expected integer;
  ready integer; picked integer; backorder integer;
begin
  select * into balance from private.order_financial_balance(p_order_id);
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode='P0002'; end if;
  if (balance.adjustment_id is null and not exists(select 1 from app.payments
      where order_id=p_order_id and status='paid'))
    or (balance.adjustment_id is not null and balance.effective_status <> 'paid')
  then next_status := 'Nog niet betaald';
  elsif balance.adjustment_id is not null and not private.package_variant_sizes_complete(p_order_id,
    (select active_package_snapshot_id from app.member_orders where id=p_order_id))
  then next_status := 'Maten invullen';
  else
    q:=private.package_fulfilment_quantities(p_order_id);
    expected:=(q->>'expectedQuantity')::integer; ready:=(q->>'readyQuantity')::integer;
    picked:=(q->>'pickedUpQuantity')::integer; backorder:=(q->>'backorderQuantity')::integer;
    next_status:=case when expected>0 and picked=expected then 'Afgerond'
      when picked>0 then 'Gedeeltelijk afgehaald'
      when ready>0 and (backorder>0 or ready<expected) then 'Gedeeltelijk af te halen'
      when expected>0 and ready=expected then 'Volledig af te halen' else 'Nalevering' end;
  end if;
  update app.member_orders set order_status=next_status,updated_at=timezone('utc',now())
  where id=p_order_id;
  return next_status;
end;
$$;

create or replace function private.order_qr_business_eligible(p_order_id uuid)
returns boolean language sql stable security definer
set search_path=app,private,pg_temp as $$
  select exists(select 1 from app.member_orders orders
    join app.member_seasons ms on ms.id=orders.member_season_id
      and ms.participation_status='active' and ms.reconciliation_status='resolved'
    join app.seasons season on season.id=orders.season_id and season.status='open'
    join app.app_settings settings on settings.id=true
      and settings.active_season_id=orders.season_id
      and length(btrim(coalesce(settings.pickup_location,''))) between 4 and 240
    join lateral private.order_financial_balance(orders.id) balance on true
    where orders.id=p_order_id
      and ((balance.adjustment_id is not null and balance.effective_status='paid'
          and balance.reconciliation_conflict_count=0)
        or (balance.adjustment_id is null and exists(select 1 from app.payments payment
          where payment.order_id=orders.id and payment.status='paid'
            and payment.reconciliation_issue is null
            and payment.amount_cents=orders.amount_due_cents and payment.currency='EUR'
            and payment.member_season_id=orders.member_season_id
            and payment.package_snapshot_id is not distinct from orders.active_package_snapshot_id)
          and not exists(select 1 from app.payments payment where payment.order_id=orders.id
            and (payment.status='duplicate_paid' or payment.reconciliation_issue is not null))))
      and (balance.adjustment_id is null
        or private.package_variant_sizes_complete(orders.id,orders.active_package_snapshot_id))
      and (balance.adjustment_id is null or not exists(select 1 from app.order_package_snapshot_items item
        left join app.order_lines line on line.id=item.order_line_id and line.status<>'cancelled'
        where item.snapshot_id=orders.active_package_snapshot_id and line.id is null))
      and exists(select 1 from app.inventory_allocations allocation
        join app.order_lines line on line.id=allocation.order_line_id
          and line.order_id=allocation.order_id and line.article_variant_id=allocation.article_variant_id
          and line.status='ready_for_pickup' and line.quantity=allocation.quantity
        where allocation.order_id=orders.id and allocation.status='reserved'
          and allocation.reconciliation_status='resolved'
          and allocation.paid_at is not null and allocation.size_valid_at is not null));
$$;
revoke all on function private.order_qr_business_eligible(uuid)
from public,anon,authenticated,service_role;

create or replace function public.get_parent_package_workspace_v8(p_token_hash text)
returns jsonb language plpgsql stable security definer
set search_path=app,private,public,pg_temp as $$
declare workspace jsonb; members jsonb;
begin
  workspace := public.get_parent_package_workspace_v7(p_token_hash);
  select coalesce(jsonb_agg(case when member.value->'order' is null then member.value else
    jsonb_set(member.value,'{order}',member.value->'order' || jsonb_build_object(
      'amountDueCents',balance.remaining_due_cents,
      'paymentStatus',case when balance.effective_status='reconciliation_required'
        then 'open' else balance.effective_status end,
      'activePackagePriceCents',balance.active_package_price_cents,
      'appliedCreditCents',balance.applied_credit_cents,
      'successfulPaymentCents',balance.successful_payment_cents,
      'remainingDueCents',balance.remaining_due_cents,
      'refundDueCents',balance.refund_due_cents,
      'refundCompletedCents',balance.refund_completed_cents,
      'refundOutstandingCents',balance.refund_outstanding_cents,
      'financialReconciliationRequired',balance.reconciliation_conflict_count>0
    ),true) end order by member.ordinality),'[]'::jsonb) into members
  from jsonb_array_elements(workspace->'members') with ordinality member(value,ordinality)
  left join lateral private.order_financial_balance(
    nullif(member.value#>>'{order,id}','')::uuid
  ) balance on member.value->'order' is not null;
  return jsonb_set(workspace,'{members}',members,true);
end;
$$;
revoke all on function public.get_parent_package_workspace_v8(text)
from public,anon,authenticated;
grant execute on function public.get_parent_package_workspace_v8(text) to service_role;

alter function app.get_payment_workspace()
rename to get_payment_workspace_before_package_finance;
revoke all on function app.get_payment_workspace_before_package_finance()
from public,anon,authenticated,service_role;

create or replace function app.get_payment_workspace()
returns jsonb language plpgsql stable security definer
set search_path=app,private,pg_temp as $$
declare base jsonb; v_active_season_id uuid;
begin
  if app.staff_role() not in ('beheerder','kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode='42501'; end if;
  base := app.get_payment_workspace_before_package_finance();
  select settings.active_season_id into v_active_season_id
  from app.app_settings settings where settings.id=true;
  return base || jsonb_build_object(
    'canRecordRefund',app.staff_role()='beheerder',
    'summary',(base->'summary') || jsonb_build_object(
      'refundProcessing',(select count(*) from app.package_refunds refund
        join app.member_orders orders on orders.id=refund.order_id
        where orders.season_id=v_active_season_id and refund.status in
          ('requesting','queued','pending','processing')),
      'manualRefundRequired',(select count(*) from app.package_refunds refund
        join app.member_orders orders on orders.id=refund.order_id
        where orders.season_id=v_active_season_id and refund.status='manual_due'),
      'additionalPaymentRequired',(select count(*) from app.member_orders orders
        join lateral private.order_financial_balance(orders.id) balance on true
        where orders.season_id=v_active_season_id and balance.remaining_due_cents>0
          and balance.adjustment_id is not null),
      'refundReconciliationRequired',(select count(*) from app.package_refunds refund
        join app.member_orders orders on orders.id=refund.order_id
        where orders.season_id=v_active_season_id
          and refund.status in ('failed','canceled','reconciliation_required'))
    ),
    'refunds',coalesce((select jsonb_agg(jsonb_build_object(
      'refundId',refund.id,'paymentId',refund.payment_id,'orderId',refund.order_id,
      'memberName',concat_ws(' ',member.first_name,member.insertion,member.last_name),
      'relationNumber',member.relation_number,
      'method',refund.method::text,'amountCents',refund.amount_cents,
      'currency',refund.currency,'status',refund.status,
      'providerRefundId',refund.provider_refund_id,
      'providerStatus',refund.provider_status,'retryable',refund.retryable,
      'fromPackage',from_snapshot.package_name,'toPackage',to_snapshot.package_name,
      'createdAt',refund.created_at,'updatedAt',refund.updated_at
    ) order by refund.created_at desc,refund.id desc)
      from (
        select refund.*
        from app.package_refunds refund
        join app.member_orders orders on orders.id=refund.order_id
          and orders.season_id=v_active_season_id
        order by refund.created_at desc,refund.id desc
        limit 100
      ) refund
      join app.package_financial_adjustments adjustment on adjustment.id=refund.adjustment_id
      join app.order_package_snapshots from_snapshot on from_snapshot.id=adjustment.from_package_snapshot_id
      join app.order_package_snapshots to_snapshot on to_snapshot.id=adjustment.to_package_snapshot_id
      join app.member_orders orders on orders.id=refund.order_id
      join app.member_seasons ms on ms.id=orders.member_season_id
      join app.members member on member.id=ms.member_id),'[]'::jsonb)
  );
end;
$$;
revoke all on function app.get_payment_workspace() from public,anon;
grant execute on function app.get_payment_workspace() to authenticated;

create or replace function public.confirm_parent_package_sizes_v5(
  p_token_hash text,p_member_season_id uuid,p_selections jsonb,
  p_expected_revision text,p_request_id uuid,p_correlation_id uuid default null
) returns jsonb language plpgsql security definer
set search_path=app,private,public,pg_temp as $$
declare target_order_id uuid; result jsonb;
begin
  if private.parent_account_for_member_season(p_token_hash,p_member_season_id) is null then
    return public.confirm_parent_package_sizes_v5_before_paid_lock(
      p_token_hash,p_member_season_id,p_selections,p_expected_revision,p_request_id,p_correlation_id);
  end if;
  select id into target_order_id from app.member_orders
  where member_season_id=p_member_season_id for update;
  if p_selections is null or jsonb_typeof(p_selections)<>'array' or exists(
    select 1 from jsonb_array_elements(case when jsonb_typeof(p_selections)='array'
      then p_selections else '[]'::jsonb end) submitted
    where jsonb_typeof(submitted.value)<>'object'
      or coalesce(submitted.value->>'articleId','') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      or coalesce(submitted.value->>'kind','') not in ('variant','other')
      or (submitted.value->>'kind'='variant' and coalesce(submitted.value->>'variantId','') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
  ) then return public.confirm_parent_package_sizes_v5_before_paid_lock(
    p_token_hash,p_member_season_id,p_selections,p_expected_revision,p_request_id,p_correlation_id);
  end if;
  result:=public.confirm_parent_package_sizes_v5_before_paid_lock(
    p_token_hash,p_member_season_id,p_selections,p_expected_revision,p_request_id,p_correlation_id);
  if (private.order_has_effective_paid_payment(target_order_id)
      or (not exists(select 1 from app.package_financial_adjustments adjustment
          join app.member_orders orders on orders.active_package_snapshot_id=adjustment.to_package_snapshot_id
          where orders.id=target_order_id)
        and exists(select 1 from app.payments payment
          where payment.order_id=target_order_id and payment.status='paid')))
    and exists(select 1 from app.member_orders orders
      where orders.id=target_order_id and orders.package_revision_id is not null)
    and private.package_variant_sizes_complete(target_order_id,
      (select active_package_snapshot_id from app.member_orders where id=target_order_id))
  then
    perform private.ensure_package_size_lifecycle(target_order_id);
    perform app.refresh_order_status(target_order_id);
  end if;
  return result;
end;
$$;
revoke all on function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid)
from public,anon,authenticated;
grant execute on function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid)
to service_role;

create or replace function app.guard_paid_order_amount()
returns trigger language plpgsql set search_path=app,private,pg_temp as $$
begin
  if new.amount_due_cents is distinct from old.amount_due_cents
    and exists(select 1 from app.payments where order_id=old.id and status='paid')
  then
    if current_setting('app.package_change_internal',true)='on'
      and new.package_revision_id is distinct from old.package_revision_id
      and new.amount_due_cents=(select revision.price_cents
        from app.package_template_revisions revision
        where revision.id=new.package_revision_id and revision.status='published' and revision.active)
    then perform private.require_admin_aal2(); return new; end if;
    raise exception 'PAID_ORDER_IMMUTABLE' using errcode='23514';
  end if;
  return new;
end;
$$;

create or replace function private.require_package_financial_adjustment_after_paid_change()
returns trigger language plpgsql security definer
set search_path=app,private,pg_temp as $$
begin
  if new.amount_due_cents is distinct from old.amount_due_cents
    and exists(select 1 from app.payments where order_id=old.id and status='paid')
    and not exists(select 1 from app.package_financial_adjustments adjustment
      where adjustment.order_id=new.id
        and adjustment.from_package_snapshot_id=old.active_package_snapshot_id
        and adjustment.to_package_snapshot_id=new.active_package_snapshot_id
        and adjustment.to_package_revision_id=new.package_revision_id)
  then raise exception 'PACKAGE_FINANCIAL_ADJUSTMENT_REQUIRED' using errcode='23514'; end if;
  return new;
end;
$$;
drop trigger if exists member_orders_require_financial_adjustment on app.member_orders;
create constraint trigger member_orders_require_financial_adjustment
after update of amount_due_cents,package_revision_id,active_package_snapshot_id
on app.member_orders deferrable initially deferred
for each row execute function private.require_package_financial_adjustment_after_paid_change();
revoke all on function private.require_package_financial_adjustment_after_paid_change()
from public,anon,authenticated,service_role;

notify pgrst, 'reload schema';
