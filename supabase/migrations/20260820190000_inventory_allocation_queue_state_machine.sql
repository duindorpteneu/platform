-- Inventory allocation is a coalescing queue: one row represents the latest
-- requested generation for a season/variant pair. A queued row is always
-- runnable; exhausted work is terminal failed work and never masquerades as
-- queued work.

create or replace function private.inventory_allocation_max_attempts()
returns integer
language sql
immutable
set search_path = pg_temp
as $$
  select 10;
$$;

revoke all on function private.inventory_allocation_max_attempts()
from public, anon, authenticated, service_role;

alter table private.inventory_allocation_queue
  add column requested_generation bigint not null default 1,
  add column processing_generation bigint;

update private.inventory_allocation_queue
set attempts = private.inventory_allocation_max_attempts()
where attempts > private.inventory_allocation_max_attempts();

update private.inventory_allocation_queue
set processing_generation = requested_generation
where status = 'processing';

create or replace function private.inventory_queue_has_allocatable_demand(
  p_season_id uuid,
  p_variant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    join lateral (
      select 1
      from app.payments payment
      where payment.order_id = orders.id
        and payment.status = 'paid'
        and payment.reconciliation_issue is null
      limit 1
    ) paid on true
    join app.member_article_sizes size_profile
      on size_profile.member_season_id = orders.member_season_id
      and size_profile.article_id = line.article_id
      and size_profile.article_variant_id = line.article_variant_id
      and size_profile.selection_status in ('confirmed', 'locked')
      and size_profile.confirmed_at is not null
    where orders.season_id = p_season_id
      and line.article_variant_id = p_variant_id
      and line.status = 'backorder'
      and private.order_has_effective_paid_payment(orders.id)
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      )
  );
$$;

revoke all on function private.inventory_queue_has_allocatable_demand(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.reconcile_exhausted_inventory_queue_v1()
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  reset_count integer;
  completed_count integer;
begin
  with repaired as (
    update private.inventory_allocation_queue queue
    set status = 'queued',
        attempts = 0,
        requested_generation = requested_generation + 1,
        processing_generation = null,
        queued_at = clock_timestamp(),
        started_at = null,
        completed_at = null,
        last_error_code = null,
        updated_at = clock_timestamp()
    where queue.status = 'queued'
      and queue.attempts >= private.inventory_allocation_max_attempts()
      and private.inventory_queue_has_allocatable_demand(
        queue.season_id,
        queue.article_variant_id
      )
    returning 1
  )
  select count(*) into reset_count from repaired;

  with repaired as (
    update private.inventory_allocation_queue queue
    set status = 'completed',
        attempts = least(
          attempts,
          private.inventory_allocation_max_attempts()
        ),
        processing_generation = null,
        started_at = null,
        completed_at = clock_timestamp(),
        last_error_code = null,
        updated_at = clock_timestamp()
    where queue.status = 'queued'
      and queue.attempts >= private.inventory_allocation_max_attempts()
      and not private.inventory_queue_has_allocatable_demand(
        queue.season_id,
        queue.article_variant_id
      )
    returning 1
  )
  select count(*) into completed_count from repaired;

  return jsonb_build_object(
    'reset', reset_count,
    'completed', completed_count
  );
end;
$$;

revoke all on function private.reconcile_exhausted_inventory_queue_v1()
from public, anon, authenticated, service_role;

do $$
declare
  repair_result jsonb;
begin
  repair_result := private.reconcile_exhausted_inventory_queue_v1();

  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260820190000_inventory_allocation_queue_state_machine',
    'passed',
    jsonb_build_object(
      'strategy', 'repair exhausted queue rows before enforcing runnable queued invariant',
      'reset', (repair_result->>'reset')::integer,
      'completed', (repair_result->>'completed')::integer
    )
  );
end;
$$;

alter table private.inventory_allocation_queue
  drop constraint inventory_allocation_queue_attempts_check,
  add constraint inventory_allocation_queue_attempts_check check (
    attempts between 0 and private.inventory_allocation_max_attempts()
  ),
  add constraint inventory_allocation_queue_generation_check check (
    requested_generation > 0
    and (
      (status = 'processing'
        and processing_generation between 1 and requested_generation)
      or (status <> 'processing' and processing_generation is null)
    )
  ),
  add constraint inventory_allocation_queue_queued_runnable_check check (
    status <> 'queued'
    or attempts < private.inventory_allocation_max_attempts()
  );

create index inventory_allocation_queue_runnable_idx
  on private.inventory_allocation_queue(queued_at, season_id, article_variant_id)
  where status in ('queued', 'failed')
    and attempts < private.inventory_allocation_max_attempts();

create or replace function private.enqueue_inventory_variant(
  p_season_id uuid,
  p_variant_id uuid,
  p_reason_code text
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if p_season_id is null
    or p_variant_id is null
    or p_reason_code !~ '^[a-z][a-z0-9._-]{2,79}$'
  then
    raise exception 'INVENTORY_QUEUE_INPUT_INVALID' using errcode = '22023';
  end if;

  insert into private.inventory_allocation_queue as queue(
    season_id,
    article_variant_id,
    status,
    reason_code,
    attempts,
    requested_generation,
    processing_generation,
    queued_at,
    started_at,
    completed_at,
    last_error_code,
    updated_at
  ) values (
    p_season_id,
    p_variant_id,
    'queued',
    p_reason_code,
    0,
    1,
    null,
    clock_timestamp(),
    null,
    null,
    null,
    clock_timestamp()
  )
  on conflict (season_id, article_variant_id) do update
  set status = case
        when queue.status = 'processing' then queue.status
        else 'queued'::app.inventory_queue_status
      end,
      reason_code = excluded.reason_code,
      attempts = case
        when queue.status = 'processing' then queue.attempts
        when queue.status = 'completed'
          or queue.attempts >= private.inventory_allocation_max_attempts()
        then 0
        else queue.attempts
      end,
      requested_generation = queue.requested_generation + 1,
      processing_generation = case
        when queue.status = 'processing' then queue.processing_generation
        else null
      end,
      queued_at = clock_timestamp(),
      started_at = case
        when queue.status = 'processing' then queue.started_at
        else null
      end,
      completed_at = null,
      last_error_code = case
        when queue.status = 'processing' then queue.last_error_code
        else null
      end,
      updated_at = clock_timestamp();
end;
$$;

revoke all on function private.enqueue_inventory_variant(uuid, uuid, text)
from public, anon, authenticated, service_role;

-- The allocator now distinguishes ordinary insufficient stock from a genuine
-- concurrent row mutation. The global inventory mutation lock makes the
-- availability proof stable for the duration of this allocator transaction.
create or replace function private.allocate_inventory_fifo_variant(
  p_season_id uuid,
  p_variant_id uuid,
  p_source_type text default 'allocator',
  p_source_id uuid default null,
  p_actor uuid default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  candidate record;
  allocation_id uuid;
  current_available bigint;
  allocated_lines integer := 0;
  allocated_quantity integer := 0;
  outcome text := 'completed';
begin
  if p_season_id is null
    or p_variant_id is null
    or p_source_type !~ '^[a-z][a-z0-9_]{1,63}$'
  then
    raise exception 'INVENTORY_ALLOCATOR_INPUT_INVALID' using errcode = '22023';
  end if;
  perform private.lock_inventory_mutation();

  loop
    select
      line.id order_line_id,
      line.quantity,
      greatest(payment.paid_at, size_profile.confirmed_at) priority_at
    into candidate
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    join lateral (
      select payment.paid_at
      from app.payments payment
      where payment.order_id = orders.id
        and payment.status = 'paid'
        and payment.reconciliation_issue is null
      order by payment.paid_at, payment.created_at, payment.id
      limit 1
    ) payment on true
    join app.member_article_sizes size_profile
      on size_profile.member_season_id = orders.member_season_id
      and size_profile.article_id = line.article_id
      and size_profile.article_variant_id = line.article_variant_id
      and size_profile.selection_status in ('confirmed', 'locked')
      and size_profile.confirmed_at is not null
    where orders.season_id = p_season_id
      and line.article_variant_id = p_variant_id
      and line.status = 'backorder'
      and private.order_has_effective_paid_payment(orders.id)
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      )
    order by greatest(payment.paid_at, size_profile.confirmed_at),
      line.created_at, line.id
    limit 1;
    exit when not found;

    select balance.available into current_available
    from private.inventory_balance(p_season_id, p_variant_id) balance;
    if current_available < candidate.quantity then
      outcome := 'insufficient_stock';
      exit;
    end if;

    allocation_id := private.reserve_inventory_order_line(
      candidate.order_line_id,
      'fifo',
      p_actor,
      null,
      p_source_type,
      p_source_id,
      p_correlation_id
    );
    if allocation_id is null then
      outcome := 'concurrent_mutation';
      exit;
    end if;
    allocated_lines := allocated_lines + 1;
    allocated_quantity := allocated_quantity + candidate.quantity;
  end loop;

  perform private.refresh_inventory_variant_actions(
    p_season_id,
    p_variant_id,
    p_source_type,
    p_source_id
  );
  perform private.refresh_paid_waiting_actions(p_season_id, p_variant_id);

  return jsonb_build_object(
    'seasonId', p_season_id,
    'variantId', p_variant_id,
    'allocatedLines', allocated_lines,
    'allocatedQuantity', allocated_quantity,
    'outcome', outcome,
    'blockedByConcurrentMutation', outcome = 'concurrent_mutation'
  );
end;
$$;

revoke all on function private.allocate_inventory_fifo_variant(
  uuid, uuid, text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

-- Releasing a hard reservation makes stock available. Previously the poisoned
-- always-queued row happened to provide a later retry; once completed really
-- means completed, the release itself must explicitly request new work.
alter function private.release_order_inventory_allocations(
  uuid, text, uuid, text, uuid, uuid
) rename to release_order_inventory_allocations_before_queue_state_machine;

revoke all on function private.release_order_inventory_allocations_before_queue_state_machine(
  uuid, text, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.release_order_inventory_allocations(
  p_order_id uuid,
  p_reason text,
  p_actor uuid,
  p_source_type text,
  p_source_id uuid,
  p_correlation_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  released_count integer;
  target_allocation_ids uuid[];
  target record;
begin
  perform private.lock_inventory_mutation();
  select coalesce(array_agg(allocation.id), array[]::uuid[])
  into target_allocation_ids
  from app.inventory_allocations allocation
  where allocation.order_id = p_order_id
    and allocation.status = 'reserved';

  released_count := private.release_order_inventory_allocations_before_queue_state_machine(
    p_order_id,
    p_reason,
    p_actor,
    p_source_type,
    p_source_id,
    p_correlation_id
  );

  if released_count > 0 then
    for target in
      select distinct allocation.season_id, allocation.article_variant_id
      from app.inventory_allocations allocation
      where allocation.id = any(target_allocation_ids)
        and allocation.status = 'released'
        and allocation.article_variant_id is not null
    loop
      perform private.enqueue_inventory_variant(
        target.season_id,
        target.article_variant_id,
        'inventory.allocation_released'
      );
    end loop;
  end if;
  return released_count;
end;
$$;

revoke all on function private.release_order_inventory_allocations(
  uuid, text, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function app.process_inventory_allocation_queue(
  p_limit integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  job record;
  processed integer := 0;
  completed integer := 0;
  retryable integer := 0;
  exhausted integer := 0;
  failed integer := 0;
  allocation_result jsonb;
  claimed_attempt integer;
  claimed_generation bigint;
  allocation_run_id uuid := gen_random_uuid();
  exhaustion_key text;
begin
  if p_limit not between 1 and 100 then
    raise exception 'INVENTORY_QUEUE_LIMIT_INVALID' using errcode = '22023';
  end if;
  if not private.inventory_v2_enabled() then
    return jsonb_build_object(
      'processed', 0,
      'completed', 0,
      'retryable', 0,
      'exhausted', 0,
      'failed', 0,
      'disabled', true
    );
  end if;

  for job in
    select queue.season_id, queue.article_variant_id, queue.reason_code
    from private.inventory_allocation_queue queue
    where queue.status in ('queued', 'failed')
      and queue.attempts < private.inventory_allocation_max_attempts()
    order by queue.queued_at, queue.season_id, queue.article_variant_id
    for update skip locked
    limit p_limit
  loop
    update private.inventory_allocation_queue
    set status = 'processing',
        attempts = attempts + 1,
        processing_generation = requested_generation,
        started_at = clock_timestamp(),
        completed_at = null,
        last_error_code = null,
        updated_at = clock_timestamp()
    where season_id = job.season_id
      and article_variant_id = job.article_variant_id
    returning attempts, processing_generation
    into claimed_attempt, claimed_generation;

    begin
      allocation_result := private.allocate_inventory_fifo_variant(
        job.season_id,
        job.article_variant_id,
        'allocation_queue',
        allocation_run_id,
        null,
        null
      );
      processed := processed + 1;
      exhaustion_key := private.inventory_action_key(
        'inventory-allocation-exhausted-v1',
        job.season_id,
        job.article_variant_id
      );

      if exists(
        select 1
        from private.inventory_allocation_queue queue
        where queue.season_id = job.season_id
          and queue.article_variant_id = job.article_variant_id
          and queue.requested_generation > claimed_generation
      ) then
        update private.inventory_allocation_queue
        set status = 'queued',
            attempts = 0,
            processing_generation = null,
            started_at = null,
            completed_at = null,
            last_error_code = null,
            updated_at = clock_timestamp()
        where season_id = job.season_id
          and article_variant_id = job.article_variant_id;
        retryable := retryable + 1;
      elsif allocation_result->>'outcome' = 'concurrent_mutation'
        and claimed_attempt >= private.inventory_allocation_max_attempts()
      then
        update private.inventory_allocation_queue
        set status = 'failed',
            processing_generation = null,
            completed_at = clock_timestamp(),
            last_error_code = 'concurrent_mutation_exhausted',
            updated_at = clock_timestamp()
        where season_id = job.season_id
          and article_variant_id = job.article_variant_id;
        perform private.open_action_item(
          'inventory_allocation_exhausted',
          job.season_id,
          'article_variant',
          job.article_variant_id,
          'allocation_queue',
          allocation_run_id,
          exhaustion_key,
          'critical'::app.action_item_severity,
          'operations'::app.action_item_visibility,
          'inventory.allocation_exhausted',
          jsonb_build_object(
            'variantId', job.article_variant_id,
            'runId', allocation_run_id,
            'attempt', claimed_attempt
          ),
          null
        );
        exhausted := exhausted + 1;
      elsif allocation_result->>'outcome' = 'concurrent_mutation' then
        update private.inventory_allocation_queue
        set status = 'queued',
            processing_generation = null,
            started_at = null,
            completed_at = null,
            last_error_code = 'concurrent_mutation_retry',
            updated_at = clock_timestamp()
        where season_id = job.season_id
          and article_variant_id = job.article_variant_id;
        retryable := retryable + 1;
      else
        update private.inventory_allocation_queue
        set status = 'completed',
            processing_generation = null,
            completed_at = clock_timestamp(),
            last_error_code = null,
            updated_at = clock_timestamp()
        where season_id = job.season_id
          and article_variant_id = job.article_variant_id;
        perform private.auto_resolve_action_item(
          'inventory_allocation_exhausted',
          job.season_id,
          exhaustion_key,
          'system: voorraadallocatiecyclus is weer succesvol afgerond'
        );
        completed := completed + 1;
      end if;
    exception when others then
      update private.inventory_allocation_queue
      set status = 'failed',
          processing_generation = null,
          last_error_code = sqlstate,
          completed_at = clock_timestamp(),
          updated_at = clock_timestamp()
      where season_id = job.season_id
        and article_variant_id = job.article_variant_id;
      failed := failed + 1;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed,
    'completed', completed,
    'retryable', retryable,
    'exhausted', exhausted,
    'failed', failed,
    'disabled', false
  );
end;
$$;

revoke all on function app.process_inventory_allocation_queue(integer)
from public, anon, authenticated, service_role;
grant execute on function app.process_inventory_allocation_queue(integer)
to service_role;

-- Keep waiting-stock mail pending only while the queue has processing or
-- retryable work. Terminal exhaustion cannot hold an event indefinitely.
alter function private.mail_v2_event_state(uuid)
rename to mail_v2_event_state_v5;

create or replace function private.mail_v2_event_state(
  p_event_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  base_state text;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  base_state := private.mail_v2_event_state_v5(p_event_id);

  if not found
    or target.template_key <> 'payment_received_waiting_stock'
    or base_state not in ('pending', 'eligible')
  then
    return base_state;
  end if;

  if exists(
    select 1
    from app.order_lines line
    join private.inventory_allocation_queue queue
      on queue.season_id = target.season_id
      and queue.article_variant_id = line.article_variant_id
    where line.order_id = target.order_id
      and line.status = 'backorder'
      and (
        queue.status = 'processing'
        or (
          queue.status in ('queued', 'failed')
          and queue.attempts < private.inventory_allocation_max_attempts()
        )
      )
  ) then
    return 'pending';
  end if;
  return 'eligible';
end;
$$;

revoke all on function private.mail_v2_event_state_v5(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_event_state(uuid)
from public, anon, authenticated, service_role;

-- Expose queue integrity separately from scheduler liveness. Terminal
-- exhaustion is actionable business state; it must not make the worker itself
-- look dead and thereby recreate the lifecycle deadlock.
alter function app.get_operational_health_v13(text, integer, text, integer)
rename to get_operational_health_v13_before_inventory_queue;

revoke all on function app.get_operational_health_v13_before_inventory_queue(
  text, integer, text, integer
) from public, anon, authenticated, service_role;

create function app.get_operational_health_v13(
  p_current_pepper_fingerprint text,
  p_current_key_version integer,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot jsonb := app.get_operational_health_v13_before_inventory_queue(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
  queue_health jsonb;
begin
  select jsonb_build_object(
    'runnable', count(*) filter (
      where status in ('queued', 'failed')
        and attempts < private.inventory_allocation_max_attempts()
    ),
    'processing', count(*) filter (where status = 'processing'),
    'terminalExhausted', count(*) filter (
      where status = 'failed'
        and attempts >= private.inventory_allocation_max_attempts()
    ),
    'poisoned', count(*) filter (
      where status = 'queued'
        and attempts >= private.inventory_allocation_max_attempts()
    ),
    'oldestRunnableAt', min(queued_at) filter (
      where status in ('queued', 'failed')
        and attempts < private.inventory_allocation_max_attempts()
    )
  ) into queue_health
  from private.inventory_allocation_queue;

  return jsonb_set(
    snapshot,
    '{inventoryAllocationQueue}',
    queue_health,
    true
  );
end;
$$;

revoke all on function app.get_operational_health_v13(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v13(
  text, integer, text, integer
) to service_role;

notify pgrst, 'reload schema';
