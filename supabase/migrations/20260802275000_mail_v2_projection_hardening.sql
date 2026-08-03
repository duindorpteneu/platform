-- Mail-v2 projection hardening. Suppressions become terminal facts, pickup
-- notifications bind to one concrete allocation episode and stale workers
-- cannot mutate a reclaimed projection.

alter table private.email_jobs
  drop constraint email_jobs_status_check;
alter table private.email_jobs
  add constraint email_jobs_status_check check (
    status in (
      'queued',
      'processing',
      'retry',
      'sent',
      'failed',
      'delivery_uncertain',
      'superseded'
    )
  );

create or replace function private.produce_internal_email_failure_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_season_id uuid;
  reason text;
  action_key text;
begin
  if not private.mail_templates_v2_cutover_started()
    or new.template_key = 'internal_email_failure'
    or not (
      (
        new.status = 'failed'
        and old.status is distinct from new.status
        and coalesce(new.last_error, '') not in (
          'access_inactive_before_send',
          'eligibility_changed_before_send',
          'mail_v2_paused',
          'superseded_by_back_in_stock'
        )
      )
      or (
        new.delivery_status in ('bounced', 'dropped', 'failed')
        and old.delivery_status is distinct from new.delivery_status
      )
    )
  then
    return new;
  end if;
  target_season_id := coalesce(
    new.season_id,
    (
      select orders.season_id
      from app.member_orders orders
      where orders.id = new.order_id
    ),
    (
      select batch.season_id
      from private.parent_access_batches batch
      where batch.id = new.parent_access_batch_id
    )
  );
  if target_season_id is null then
    return new;
  end if;
  reason := case
    when new.delivery_status in ('bounced', 'dropped', 'failed')
      then 'provider_' || new.delivery_status
    else coalesce(new.last_error, 'terminal_failure')
  end;
  if reason !~ '^[a-z0-9][a-z0-9._-]{1,63}$' then
    reason := 'terminal_failure';
  end if;
  action_key := encode(
    extensions.digest(
      convert_to('email-failure-v2:' || new.id::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform private.open_action_item(
    'email_failure',
    target_season_id,
    'email_job',
    new.id,
    'email_job',
    new.id,
    action_key,
    'critical',
    'admin_only',
    'email.' || reason,
    jsonb_build_object('jobId', new.id),
    statement_timestamp() + interval '4 hours'
  );
  insert into private.mail_v2_domain_events(
    template_key,
    parent_account_id,
    season_id,
    member_season_id,
    order_id,
    order_line_id,
    source_type,
    source_id,
    cohort_id,
    idempotency_key,
    payload_snapshot
  ) values (
    'internal_email_failure',
    null,
    target_season_id,
    null,
    null,
    null,
    'email_job',
    new.id,
    new.id,
    'internal-email-failure-v2:' || new.id::text,
    jsonb_build_object('jobId', new.id, 'reason', reason)
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

revoke all on function private.produce_internal_email_failure_v2()
from public, anon, authenticated, service_role;

alter table private.mail_v2_event_suppressions
  drop constraint mail_v2_event_suppressions_binding_check;
alter table private.mail_v2_event_suppressions
  drop constraint mail_v2_event_suppressions_reason_check;
alter table private.mail_v2_event_suppressions
  add constraint mail_v2_event_suppressions_reason_check check (
    reason in (
      'eligibility_inactive',
      'superseded_by_back_in_stock',
      'out_of_stock_resolved_by_back_in_stock',
      'out_of_stock_resolved_by_pickup_delivery',
      'retry_exhausted'
    )
  ),
  add constraint mail_v2_event_suppressions_binding_check check (
    (
      reason in (
        'superseded_by_back_in_stock',
        'out_of_stock_resolved_by_back_in_stock',
        'out_of_stock_resolved_by_pickup_delivery'
      )
      and superseding_event_id is not null
      and superseding_event_id <> event_id
    )
    or (
      reason not in (
        'superseded_by_back_in_stock',
        'out_of_stock_resolved_by_back_in_stock',
        'out_of_stock_resolved_by_pickup_delivery'
      )
      and superseding_event_id is null
    )
  );

create or replace function private.mail_v2_open_out_of_stock_event_id(
  p_parent_account_id uuid,
  p_order_line_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select event.id
  from private.mail_v2_domain_events event
  join private.mail_v2_projections projection
    on projection.event_id = event.id
  join private.mail_v2_projection_batches batch
    on batch.id = projection.projection_batch_id
    and batch.status = 'queued'
  join private.email_jobs job
    on job.id = batch.email_job_id
    and job.status = 'sent'
    and coalesce(job.delivery_status, 'accepted')
      not in ('bounced', 'dropped', 'failed')
  where event.template_key = 'out_of_stock'
    and event.parent_account_id = p_parent_account_id
    and event.order_line_id = p_order_line_id
    and not exists(
      select 1
      from private.mail_v2_event_suppressions suppression
      where suppression.event_id = event.id
    )
  order by
    coalesce(job.completed_at, job.updated_at, job.created_at) desc,
    event.id desc
  limit 1;
$$;

create or replace function private.mail_v2_out_of_stock_sent(
  p_parent_account_id uuid,
  p_order_line_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select private.mail_v2_open_out_of_stock_event_id(
    p_parent_account_id,
    p_order_line_id
  ) is not null;
$$;

create or replace function private.mail_v2_out_of_stock_in_flight(
  p_parent_account_id uuid,
  p_order_line_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    join private.mail_v2_projections projection
      on projection.event_id = event.id
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
    left join private.email_jobs job
      on job.id = batch.email_job_id
    where event.template_key = 'out_of_stock'
      and event.parent_account_id = p_parent_account_id
      and event.order_line_id = p_order_line_id
      and not exists(
        select 1
        from private.mail_v2_event_suppressions suppression
        where suppression.event_id = event.id
      )
      and (
        batch.status = 'leased'
        or (
          batch.status = 'queued'
          and job.status in (
            'queued',
            'retry',
            'processing',
            'delivery_uncertain'
          )
        )
      )
  );
$$;

revoke all on function private.mail_v2_open_out_of_stock_event_id(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_out_of_stock_sent(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_out_of_stock_in_flight(uuid, uuid)
from public, anon, authenticated, service_role;

do $$
begin
  if exists(
    select 1
    from private.mail_v2_domain_events event
    where event.template_key in ('pickup_ready', 'back_in_stock')
      and (
        event.source_type <> 'inventory_allocation_event'
        or event.order_line_id is null
        or not exists(
          select 1
          from app.inventory_allocation_events allocation_event
          join app.inventory_allocations allocation
            on allocation.id = allocation_event.allocation_id
          join app.order_lines line
            on line.id = allocation.order_line_id
            and line.order_id = allocation.order_id
            and line.article_variant_id = allocation.article_variant_id
          where allocation_event.id = event.source_id
            and allocation_event.event_type = 'reserved'
            and allocation_event.next_status = 'reserved'
            and allocation.member_season_id = event.member_season_id
            and allocation.season_id = event.season_id
            and allocation.order_id = event.order_id
            and allocation.order_line_id = event.order_line_id
        )
      )
  ) then
    raise exception 'MAIL_V2_READY_SOURCE_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;
end;
$$;

create or replace function private.validate_mail_v2_ready_event_source()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if new.template_key not in ('pickup_ready', 'back_in_stock') then
    return new;
  end if;
  if new.source_type <> 'inventory_allocation_event'
    or new.order_line_id is null
    or not exists(
      select 1
      from app.inventory_allocation_events allocation_event
      join app.inventory_allocations allocation
        on allocation.id = allocation_event.allocation_id
      join app.order_lines line
        on line.id = allocation.order_line_id
        and line.order_id = allocation.order_id
        and line.article_variant_id = allocation.article_variant_id
      where allocation_event.id = new.source_id
        and allocation_event.event_type = 'reserved'
        and allocation_event.next_status = 'reserved'
        and allocation.member_season_id = new.member_season_id
        and allocation.season_id = new.season_id
        and allocation.order_id = new.order_id
        and allocation.order_line_id = new.order_line_id
    )
  then
    raise exception 'MAIL_V2_READY_SOURCE_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger mail_v2_domain_events_validate_ready_source
before insert on private.mail_v2_domain_events
for each row execute function private.validate_mail_v2_ready_event_source();

revoke all on function private.validate_mail_v2_ready_event_source()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_allocation_event_is_ready(
  p_event_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    join app.inventory_allocation_events allocation_event
      on event.source_type = 'inventory_allocation_event'
      and allocation_event.id = event.source_id
      and allocation_event.event_type = 'reserved'
      and allocation_event.next_status = 'reserved'
    join app.inventory_allocations allocation
      on allocation.id = allocation_event.allocation_id
      and allocation.status = 'reserved'
      and allocation.reconciliation_status = 'resolved'
      and allocation.member_season_id = event.member_season_id
      and allocation.season_id = event.season_id
      and allocation.order_id = event.order_id
      and allocation.order_line_id = event.order_line_id
    join app.order_lines line
      on line.id = allocation.order_line_id
      and line.order_id = allocation.order_id
      and line.article_variant_id = allocation.article_variant_id
      and line.status = 'ready_for_pickup'
    where event.id = p_event_id
      and event.template_key in ('pickup_ready', 'back_in_stock')
      and event.order_line_id is not null
  );
$$;

create or replace function private.mail_v2_ready_lines(
  p_event_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  result jsonb;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found then
    return '[]'::jsonb;
  end if;
  if target.template_key in ('pickup_ready', 'back_in_stock') then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', allocation.product_name_snapshot,
        'size', allocation.size_snapshot,
        'quantity', allocation.quantity,
        'status', 'Af te halen'
      )
      order by allocation.allocated_at, allocation.id
    ), '[]'::jsonb)
    into result
    from app.inventory_allocation_events allocation_event
    join app.inventory_allocations allocation
      on allocation.id = allocation_event.allocation_id
      and allocation.status = 'reserved'
      and allocation.reconciliation_status = 'resolved'
      and allocation.member_season_id = target.member_season_id
      and allocation.season_id = target.season_id
      and allocation.order_id = target.order_id
      and allocation.order_line_id = target.order_line_id
    join app.order_lines line
      on line.id = allocation.order_line_id
      and line.order_id = allocation.order_id
      and line.article_variant_id = allocation.article_variant_id
      and line.status = 'ready_for_pickup'
    where target.source_type = 'inventory_allocation_event'
      and allocation_event.id = target.source_id
      and allocation_event.event_type = 'reserved'
      and allocation_event.next_status = 'reserved';
    return result;
  end if;
  if target.template_key = 'pickup_reminder' then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', allocation.product_name_snapshot,
        'size', allocation.size_snapshot,
        'quantity', allocation.quantity,
        'status', 'Af te halen'
      )
      order by allocation.allocated_at, allocation.id
    ), '[]'::jsonb)
    into result
    from app.inventory_allocations allocation
    join app.order_lines line
      on line.id = allocation.order_line_id
      and line.order_id = allocation.order_id
      and line.article_variant_id = allocation.article_variant_id
      and line.status = 'ready_for_pickup'
    where allocation.order_id = target.order_id
      and allocation.member_season_id = target.member_season_id
      and allocation.season_id = target.season_id
      and allocation.status = 'reserved'
      and allocation.reconciliation_status = 'resolved';
    return result;
  end if;
  return '[]'::jsonb;
end;
$$;

revoke all on function private.mail_v2_allocation_event_is_ready(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_ready_lines(uuid)
from public, anon, authenticated, service_role;

alter function private.mail_v2_current_event_payload(uuid)
rename to mail_v2_current_event_payload_v1;

create or replace function private.mail_v2_current_event_payload(
  p_event_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_template text;
  current_payload jsonb;
begin
  current_payload := private.mail_v2_current_event_payload_v1(p_event_id);
  select event.template_key into target_template
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if current_payload is null then
    return null;
  end if;
  if target_template in (
    'pickup_ready',
    'pickup_reminder',
    'back_in_stock'
  ) then
    current_payload := jsonb_set(
      current_payload,
      '{lines}',
      private.mail_v2_ready_lines(p_event_id),
      true
    );
  end if;
  return current_payload;
end;
$$;

revoke all on function private.mail_v2_current_event_payload_v1(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_current_event_payload(uuid)
from public, anon, authenticated, service_role;

alter function private.mail_v2_event_state(uuid)
rename to mail_v2_event_state_v3;

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
  target_template text;
  target private.mail_v2_domain_events%rowtype;
begin
  if exists(
    select 1
    from private.mail_v2_event_suppressions suppression
    where suppression.event_id = p_event_id
  ) then
    return 'terminal';
  end if;
  select event.template_key into target_template
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if target_template in ('pickup_ready', 'back_in_stock')
    and not private.mail_v2_allocation_event_is_ready(p_event_id)
  then
    return 'terminal';
  end if;
  if target_template = 'back_in_stock' then
    select * into target
    from private.mail_v2_domain_events event
    where event.id = p_event_id;
    if not exists(
      select 1
      from private.mail_v2_event_suppressions suppression
      join private.mail_v2_domain_events out_of_stock
        on out_of_stock.id = suppression.event_id
        and out_of_stock.template_key = 'out_of_stock'
        and out_of_stock.parent_account_id = target.parent_account_id
        and out_of_stock.order_line_id = target.order_line_id
      where suppression.reason =
          'out_of_stock_resolved_by_back_in_stock'
        and suppression.superseding_event_id = target.id
    ) or not exists(
      select 1
      from app.member_seasons member_season
      join private.parent_portal_grants grant_row
        on grant_row.member_season_id = member_season.id
        and grant_row.parent_account_id = target.parent_account_id
        and grant_row.status = 'active'
      where member_season.id = target.member_season_id
        and member_season.season_id = target.season_id
        and member_season.participation_status = 'active'
    ) or not exists(
      select 1
      from app.member_orders orders
      where orders.id = target.order_id
        and orders.member_season_id = target.member_season_id
        and orders.season_id = target.season_id
        and orders.active_package_snapshot_id is not null
        and exists(
          select 1
          from app.order_lines line
          where line.order_id = orders.id
            and line.status <> 'cancelled'
        )
    ) or not exists(
      select 1
      from app.payments payment
      where payment.order_id = target.order_id
        and payment.status = 'paid'
        and payment.reconciliation_issue is null
    ) or not exists(
      select 1
      from app.inventory_allocations allocation
      where allocation.order_id = target.order_id
        and allocation.order_line_id = target.order_line_id
        and allocation.status = 'reserved'
    ) then
      return 'terminal';
    end if;
    return case
      when private.order_qr_usable(target.order_id) then 'eligible'
      else 'pending'
    end;
  end if;
  return private.mail_v2_event_state_v3(p_event_id);
end;
$$;

revoke all on function private.mail_v2_event_state_v3(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_event_state(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_campaign_current_episode_exists(
  p_template_key text,
  p_parent_account_id uuid,
  p_order_id uuid,
  p_order_line_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    where event.template_key = p_template_key
      and event.parent_account_id = p_parent_account_id
      and event.order_id = p_order_id
      and event.order_line_id is not distinct from p_order_line_id
      and not exists(
        select 1
        from private.mail_v2_event_suppressions suppression
        where suppression.event_id = event.id
      )
      and private.mail_v2_event_state(event.id) in ('eligible', 'pending')
      and not (
        event.template_key in (
          'payment_request',
          'available_payment_required'
        )
        and exists(
          select 1
          from app.payments payment
          where payment.order_id = event.order_id
            and payment.paid_at is not null
            and payment.paid_at >= event.created_at
        )
      )
      and not (
        event.template_key in ('size_fill_request', 'size_review_request')
        and exists(
          select 1
          from app.package_size_confirmations confirmation
          where confirmation.order_id = event.order_id
            and confirmation.created_at >= event.created_at
        )
      )
  );
$$;

revoke all on function private.mail_v2_campaign_current_episode_exists(
  text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.reconcile_mail_v2_event_supersessions()
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  back_event_id uuid;
  target_batch_id uuid;
  target_job_id uuid;
  target_batch_status text;
  target_batch_retry_count integer;
  target_job_status text;
  target_delivery_status text;
  target_out_of_stock_batch_id uuid;
  target_out_of_stock_job_id uuid;
  target_out_of_stock_batch_status text;
  target_out_of_stock_job_status text;
  target_out_of_stock_delivery_status text;
  target_allocation_id uuid;
  exhausted_batch private.mail_v2_projection_batches%rowtype;
  reconciled integer := 0;
begin
  for target in
    select
      event.*,
      open_out_of_stock.event_id as out_of_stock_event_id
    from private.mail_v2_domain_events event
    cross join lateral (
      select private.mail_v2_open_out_of_stock_event_id(
        event.parent_account_id,
        event.order_line_id
      ) event_id
    ) open_out_of_stock
    where event.template_key = 'pickup_ready'
      and event.order_line_id is not null
      and open_out_of_stock.event_id is not null
      and not exists(
        select 1
        from private.mail_v2_event_suppressions suppression
        where suppression.event_id = event.id
      )
      and private.mail_v2_allocation_event_is_ready(event.id)
      and (
        not exists(
          select 1
          from private.mail_v2_projections projection
          where projection.event_id = event.id
        )
        or exists(
          select 1
          from private.mail_v2_projections projection
          join private.mail_v2_projection_batches batch
            on batch.id = projection.projection_batch_id
          left join private.email_jobs job
            on job.id = batch.email_job_id
          where projection.event_id = event.id
            and (
              batch.status = 'leased'
              or (
                batch.status = 'queued'
                and (
                  job.status in ('queued', 'retry')
                  or (
                    job.status = 'sent'
                    and coalesce(job.delivery_status, 'accepted')
                      not in ('bounced', 'dropped', 'failed')
                  )
                )
              )
            )
        )
      )
    order by event.created_at, event.id
    limit 100
    for update of event skip locked
  loop
    target_batch_id := null;
    target_job_id := null;
    target_batch_status := null;
    target_batch_retry_count := null;
    target_job_status := null;
    target_delivery_status := null;
    target_out_of_stock_batch_id := null;
    target_out_of_stock_job_id := null;
    target_out_of_stock_batch_status := null;
    target_out_of_stock_job_status := null;
    target_out_of_stock_delivery_status := null;
    target_allocation_id := null;

    begin
      perform 1
      from private.mail_v2_domain_events event
      where event.id = target.out_of_stock_event_id
        and not exists(
          select 1
          from private.mail_v2_event_suppressions suppression
          where suppression.event_id = event.id
        )
      for update nowait;
      if not found then
        continue;
      end if;
    exception
      when lock_not_available then
        continue;
    end;

    select
      projection.projection_batch_id,
      batch.email_job_id
    into
      target_out_of_stock_batch_id,
      target_out_of_stock_job_id
    from private.mail_v2_projections projection
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
    where projection.event_id = target.out_of_stock_event_id;
    if target_out_of_stock_job_id is null then
      continue;
    end if;
    begin
      select job.status, job.delivery_status
      into
        target_out_of_stock_job_status,
        target_out_of_stock_delivery_status
      from private.email_jobs job
      where job.id = target_out_of_stock_job_id
      for update nowait;
    exception
      when lock_not_available then
        continue;
    end;
    begin
      select batch.status
      into target_out_of_stock_batch_status
      from private.mail_v2_projection_batches batch
      where batch.id = target_out_of_stock_batch_id
        and batch.email_job_id = target_out_of_stock_job_id
      for update nowait;
    exception
      when lock_not_available then
        continue;
    end;
    if target_out_of_stock_batch_status <> 'queued'
      or target_out_of_stock_job_status <> 'sent'
      or coalesce(
        target_out_of_stock_delivery_status,
        'accepted'
      ) in ('bounced', 'dropped', 'failed')
      or exists(
        select 1
        from private.mail_v2_event_suppressions suppression
        where suppression.event_id = target.out_of_stock_event_id
      )
    then
      continue;
    end if;

    begin
      select allocation.id
      into target_allocation_id
      from app.inventory_allocation_events allocation_event
      join app.inventory_allocations allocation
        on allocation.id = allocation_event.allocation_id
      where allocation_event.id = target.source_id
        and allocation_event.event_type = 'reserved'
        and allocation_event.next_status = 'reserved'
        and allocation.status = 'reserved'
        and allocation.reconciliation_status = 'resolved'
        and allocation.member_season_id = target.member_season_id
        and allocation.season_id = target.season_id
        and allocation.order_id = target.order_id
        and allocation.order_line_id = target.order_line_id
      for update of allocation nowait;
      if not found then
        continue;
      end if;
      perform 1
      from app.order_lines line
      join app.inventory_allocations allocation
        on allocation.id = target_allocation_id
        and allocation.order_line_id = line.id
        and allocation.order_id = line.order_id
        and allocation.article_variant_id = line.article_variant_id
      where line.id = target.order_line_id
        and line.order_id = target.order_id
        and line.status = 'ready_for_pickup'
      for update of line nowait;
      if not found then
        continue;
      end if;
    exception
      when lock_not_available then
        continue;
    end;

    select
      projection.projection_batch_id,
      batch.email_job_id
    into target_batch_id, target_job_id
    from private.mail_v2_projections projection
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
    where projection.event_id = target.id;

    if target_job_id is not null then
      begin
        select job.status, job.delivery_status
        into target_job_status, target_delivery_status
        from private.email_jobs job
        where job.id = target_job_id
        for update nowait;
      exception
        when lock_not_available then
          continue;
      end;
    end if;
    if target_batch_id is not null then
      begin
        select batch.status, batch.retry_count
        into target_batch_status, target_batch_retry_count
        from private.mail_v2_projection_batches batch
        where batch.id = target_batch_id
        for update nowait;
      exception
        when lock_not_available then
          continue;
      end;
    end if;

    if target_job_status in ('processing', 'delivery_uncertain') then
      continue;
    end if;
    if target_job_status = 'sent'
      and coalesce(target_delivery_status, 'accepted')
        not in ('bounced', 'dropped', 'failed')
    then
      insert into private.mail_v2_event_suppressions(
        event_id,
        reason,
        superseding_event_id
      ) values (
        target.out_of_stock_event_id,
        'out_of_stock_resolved_by_pickup_delivery',
        target.id
      ) on conflict (event_id) do nothing;
      reconciled := reconciled + 1;
      continue;
    end if;
    if target_job_status = 'failed'
      or (
        target_job_status = 'sent'
        and target_delivery_status in ('bounced', 'dropped', 'failed')
      )
    then
      continue;
    end if;

    back_event_id := private.enqueue_mail_v2_member_event(
      'back_in_stock',
      target.parent_account_id,
      target.member_season_id,
      'inventory_allocation_event',
      target.source_id,
      target.cohort_id,
      concat_ws(
        ':',
        'back-in-stock-v2',
        target.out_of_stock_event_id,
        target.source_id,
        target.parent_account_id
      ),
      target.order_line_id
    );
    insert into private.mail_v2_event_suppressions(
      event_id,
      reason,
      superseding_event_id
    ) values (
      target.id,
      'superseded_by_back_in_stock',
      back_event_id
    ) on conflict (event_id) do nothing;
    insert into private.mail_v2_event_suppressions(
      event_id,
      reason,
      superseding_event_id
    ) values (
      target.out_of_stock_event_id,
      'out_of_stock_resolved_by_back_in_stock',
      back_event_id
    ) on conflict (event_id) do nothing;

    perform set_config('app.mail_v2_projection_internal', 'on', true);
    if target_batch_status = 'leased' then
      update private.mail_v2_projection_batches
      set lease_expires_at = statement_timestamp() - interval '1 second',
          updated_at = statement_timestamp()
      where id = target_batch_id;
    elsif target_batch_status = 'queued' then
      if target_job_status in ('queued', 'retry') then
        update private.email_jobs
        set status = 'superseded',
            claim_token = null,
            claimed_at = null,
            completed_at = statement_timestamp(),
            last_error = 'superseded_by_back_in_stock',
            updated_at = statement_timestamp()
        where id = target_job_id;
      end if;
      if target_batch_retry_count < 10 then
        update private.mail_v2_projection_batches
        set status = 'leased',
            lease_token = gen_random_uuid(),
            lease_expires_at = statement_timestamp() - interval '1 second',
            email_job_id = null,
            suppression_reason = null,
            eligible_event_count = null,
            eligibility_revision = null,
            retry_count = retry_count + 1,
            updated_at = statement_timestamp()
        where id = target_batch_id;
      else
        update private.mail_v2_projection_batches
        set status = 'suppressed',
            lease_token = null,
            lease_expires_at = null,
            email_job_id = null,
            suppression_reason = 'retry_exhausted',
            eligible_event_count = null,
            eligibility_revision = null,
            updated_at = statement_timestamp()
        where id = target_batch_id
        returning * into exhausted_batch;
        insert into private.mail_v2_event_suppressions(event_id, reason)
        select projection.event_id, 'retry_exhausted'
        from private.mail_v2_projections projection
        where projection.projection_batch_id = target_batch_id
        on conflict (event_id) do nothing;
        perform private.open_mail_v2_projection_action(
          exhausted_batch,
          'retry_exhausted'
        );
      end if;
    end if;
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    reconciled := reconciled + 1;
  end loop;
  return reconciled;
exception
  when others then
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    raise;
end;
$$;

revoke all on function private.reconcile_mail_v2_event_supersessions()
from public, anon, authenticated, service_role;

create or replace function app.fail_mail_v2_domain_projection_v1(
  p_projection_batch_id uuid,
  p_lease_token uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_batch private.mail_v2_projection_batches%rowtype;
begin
  if p_projection_batch_id is null
    or p_lease_token is null
    or p_reason not in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
    )
  then
    raise exception 'MAIL_V2_DOMAIN_FAILURE_INVALID' using errcode = '22023';
  end if;
  select * into target_batch
  from private.mail_v2_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_V2_DOMAIN_PROJECTION_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  if target_batch.status = 'suppressed' then
    return jsonb_build_object(
      'groupId', target_batch.id, 'status', 'suppressed', 'reused', true
    );
  end if;
  if target_batch.status <> 'leased'
    or target_batch.lease_token is distinct from p_lease_token
    or target_batch.lease_expires_at <= statement_timestamp()
  then
    raise exception 'MAIL_V2_DOMAIN_LEASE_CONFLICT' using errcode = '40001';
  end if;
  perform set_config('app.mail_v2_projection_internal', 'on', true);
  update private.mail_v2_projection_batches
  set status = 'suppressed',
      lease_token = null,
      lease_expires_at = null,
      suppression_reason = p_reason,
      updated_at = timezone('utc', now())
  where id = target_batch.id;
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  perform private.open_mail_v2_projection_action(target_batch, p_reason);
  return jsonb_build_object(
    'groupId', target_batch.id, 'status', 'suppressed', 'reused', false
  );
exception
  when others then
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    raise;
end;
$$;

revoke all on function app.fail_mail_v2_domain_projection_v1(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function app.fail_mail_v2_domain_projection_v1(
  uuid, uuid, text
) to service_role;

create or replace function app.fail_fulfilment_mail_projection_v1(
  p_projection_batch_id uuid,
  p_lease_token uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_batch private.fulfilment_mail_projection_batches%rowtype;
begin
  if p_projection_batch_id is null
    or p_lease_token is null
    or p_reason not in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
    )
  then
    raise exception 'MAIL_PROJECTION_FAILURE_INVALID' using errcode = '22023';
  end if;
  select * into target_batch
  from private.fulfilment_mail_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_PROJECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_batch.status = 'suppressed' then
    return jsonb_build_object(
      'groupId', target_batch.id, 'status', 'suppressed', 'reused', true
    );
  end if;
  if target_batch.status <> 'leased'
    or target_batch.lease_token is distinct from p_lease_token
    or target_batch.lease_expires_at <= statement_timestamp()
  then
    raise exception 'MAIL_PROJECTION_LEASE_CONFLICT' using errcode = '40001';
  end if;
  perform set_config('app.mail_projection_internal', 'on', true);
  update private.fulfilment_mail_projection_batches
  set status = 'suppressed',
      lease_token = null,
      lease_expires_at = null,
      suppression_reason = p_reason,
      updated_at = timezone('utc', now())
  where id = target_batch.id;
  perform set_config('app.mail_projection_internal', 'off', true);
  perform private.open_mail_projection_action(target_batch, p_reason);
  return jsonb_build_object(
    'groupId', target_batch.id, 'status', 'suppressed', 'reused', false
  );
exception
  when others then
    perform set_config('app.mail_projection_internal', 'off', true);
    raise;
end;
$$;

revoke all on function app.fail_fulfilment_mail_projection_v1(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function app.fail_fulfilment_mail_projection_v1(
  uuid, uuid, text
) to service_role;

comment on function private.mail_v2_allocation_event_is_ready(uuid) is
  'Binds pickup and back-in-stock mail to one current resolved allocation episode.';
comment on function private.reconcile_mail_v2_event_supersessions() is
  'Atomically supersedes only unsent pickup jobs; uncertain delivery is deferred.';

select pg_notify('pgrst', 'reload schema');
