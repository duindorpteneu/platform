-- Recoverable mail-v2 projection failures, reconciliation-aware allocation
-- transitions and a cutover gate that proves the legacy queue is drained.

drop trigger payments_inventory_transition on app.payments;

create or replace function private.handle_payment_inventory_transition()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  old_valid boolean := false;
  new_valid boolean;
  order_has_valid_payment boolean;
begin
  if tg_op = 'UPDATE' then
    old_valid := old.status = 'paid'
      and old.reconciliation_issue is null;
  end if;
  new_valid := new.status = 'paid'
    and new.reconciliation_issue is null;

  if new_valid and not old_valid then
    for target in
      select distinct orders.season_id, line.article_variant_id
      from app.member_orders orders
      join app.order_lines line on line.order_id = orders.id
      where orders.id = new.order_id
        and line.status = 'backorder'
        and line.article_variant_id is not null
    loop
      perform private.enqueue_inventory_variant(
        target.season_id,
        target.article_variant_id,
        'payment.became_valid_paid'
      );
    end loop;
  elsif old_valid and not new_valid then
    select exists(
      select 1
      from app.payments payment
      where payment.order_id = new.order_id
        and payment.status = 'paid'
        and payment.reconciliation_issue is null
    ) into order_has_valid_payment;
    if not order_has_valid_payment then
      perform private.release_order_inventory_allocations(
        new.order_id,
        'Betaling is niet langer definitief en gereconcilieerd',
        null,
        'payment',
        new.id,
        null
      );
    end if;
  end if;
  return new;
end;
$$;

create trigger payments_inventory_transition
after insert or update of status, reconciliation_issue on app.payments
for each row execute function private.handle_payment_inventory_transition();

revoke all on function private.handle_payment_inventory_transition()
from public, anon, authenticated, service_role;

alter function private.mail_v2_event_state(uuid)
rename to mail_v2_event_state_v1;

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
  base_state text;
begin
  base_state := private.mail_v2_event_state_v1(p_event_id);
  if base_state = 'eligible'
    and exists(
      select 1
      from private.mail_v2_domain_events event
      join app.payments payment on payment.order_id = event.order_id
      where event.id = p_event_id
        and event.template_key in (
          'payment_request',
          'payment_reminder',
          'available_payment_required'
        )
        and payment.status = 'paid'
        and payment.reconciliation_issue is not null
    )
  then
    return 'pending';
  end if;
  return base_state;
end;
$$;

revoke all on function private.mail_v2_event_state_v1(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_event_state(uuid)
from public, anon, authenticated, service_role;

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
  failed integer := 0;
  allocation_result jsonb;
  allocation_run_id uuid := gen_random_uuid();
begin
  if p_limit not between 1 and 100 then
    raise exception 'INVENTORY_QUEUE_LIMIT_INVALID' using errcode = '22023';
  end if;
  if not private.inventory_v2_enabled() then
    return jsonb_build_object(
      'processed', 0,
      'failed', 0,
      'disabled', true
    );
  end if;

  for job in
    select queue.season_id, queue.article_variant_id, queue.reason_code
    from private.inventory_allocation_queue queue
    where queue.status in ('queued', 'failed')
      and queue.attempts < 10
    order by queue.queued_at, queue.season_id, queue.article_variant_id
    for update skip locked
    limit p_limit
  loop
    update private.inventory_allocation_queue
    set status = 'processing',
        attempts = attempts + 1,
        started_at = timezone('utc', now()),
        completed_at = null,
        last_error_code = null,
        updated_at = timezone('utc', now())
    where season_id = job.season_id
      and article_variant_id = job.article_variant_id;
    begin
      allocation_result := private.allocate_inventory_fifo_variant(
        job.season_id,
        job.article_variant_id,
        'allocation_queue',
        allocation_run_id,
        null,
        null
      );
      update private.inventory_allocation_queue
      set status = case
            when (allocation_result->>'blockedByConcurrentMutation')::boolean
            then 'queued'::app.inventory_queue_status
            else 'completed'::app.inventory_queue_status
          end,
          completed_at = case
            when (allocation_result->>'blockedByConcurrentMutation')::boolean
            then null
            else timezone('utc', now())
          end,
          updated_at = timezone('utc', now())
      where season_id = job.season_id
        and article_variant_id = job.article_variant_id;
      processed := processed + 1;
    exception when others then
      update private.inventory_allocation_queue
      set status = 'failed',
          last_error_code = sqlstate,
          completed_at = timezone('utc', now()),
          updated_at = timezone('utc', now())
      where season_id = job.season_id
        and article_variant_id = job.article_variant_id;
      failed := failed + 1;
    end;
  end loop;
  return jsonb_build_object(
    'processed', processed,
    'failed', failed,
    'disabled', false
  );
end;
$$;

revoke all on function app.process_inventory_allocation_queue(integer)
from public, anon, authenticated, service_role;
grant execute on function app.process_inventory_allocation_queue(integer)
to service_role;

create or replace function app.create_email_bulk(
  p_template_key text,
  p_order_ids uuid[],
  p_batch_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_template app.email_templates%rowtype;
  target_batch app.email_batches%rowtype;
  requested_count integer;
  eligible_count integer;
  selection_hash text;
  order_id uuid;
  inserted_batch boolean := false;
begin
  if actor is null
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if private.mail_templates_v2_cutover_started() then
    raise exception 'MAIL_V2_LEGACY_BULK_CLOSED' using errcode = '55000';
  end if;
  requested_count := coalesce(array_length(p_order_ids, 1), 0);
  if p_template_key not in ('payment_reminder', 'ready_for_pickup')
    or requested_count not between 1 and 2000
    or requested_count <> (
      select count(distinct value)
      from unnest(p_order_ids) value
    )
    or length(trim(p_batch_key)) not between 8 and 160
  then
    raise exception 'INVALID_EMAIL_BULK' using errcode = '22023';
  end if;
  select * into target_template
  from app.email_templates
  where template_key = p_template_key
    and active
  for share;
  if not found then
    raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514';
  end if;
  perform 1
  from app.member_orders
  where id = any(p_order_ids)
  order by id
  for update;
  select count(*) into eligible_count
  from app.member_orders orders
  where orders.id = any(p_order_ids)
    and (
      (
        p_template_key = 'payment_reminder'
        and not exists(
          select 1
          from app.payments payment
          where payment.order_id = orders.id
            and payment.status = 'paid'
        )
      )
      or (
        p_template_key = 'ready_for_pickup'
        and exists(
          select 1
          from app.payments payment
          where payment.order_id = orders.id
            and payment.status = 'paid'
        )
        and exists(
          select 1
          from app.order_lines line
          where line.order_id = orders.id
            and line.status = 'ready_for_pickup'
        )
      )
    );
  if eligible_count <> requested_count then
    raise exception 'EMAIL_BULK_SELECTION_NOT_ELIGIBLE'
      using errcode = '23514';
  end if;
  select md5(string_agg(value::text, ',' order by value))
  into selection_hash
  from unnest(p_order_ids) value;
  insert into app.email_batches(
    batch_key,
    template_id,
    selection_hash,
    selected_count,
    actor_user_id
  ) values (
    trim(p_batch_key),
    target_template.id,
    selection_hash,
    requested_count,
    actor
  )
  on conflict(batch_key) do nothing
  returning * into target_batch;
  if found then
    inserted_batch := true;
  else
    select * into target_batch
    from app.email_batches
    where batch_key = trim(p_batch_key)
    for update;
    if target_batch.template_id <> target_template.id
      or target_batch.selection_hash <> selection_hash
    then
      raise exception 'EMAIL_BATCH_KEY_CONFLICT' using errcode = '23505';
    end if;
  end if;
  foreach order_id in array p_order_ids loop
    perform private.enqueue_order_email(
      order_id,
      p_template_key,
      'bulk:' || trim(p_batch_key) || ':' || p_template_key
        || ':' || order_id::text,
      target_batch.id
    );
  end loop;
  if inserted_batch then
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    ) values (
      actor,
      'email.bulk.created',
      'email_batch',
      target_batch.id,
      jsonb_build_object(
        'template_key',
        p_template_key,
        'selected_count',
        requested_count
      )
    );
  end if;
  return jsonb_build_object(
    'batchId',
    target_batch.id,
    'templateKey',
    p_template_key,
    'jobCount',
    requested_count,
    'reused',
    not inserted_batch
  );
end;
$$;

revoke all on function app.create_email_bulk(text, uuid[], text)
from public, anon;
grant execute on function app.create_email_bulk(text, uuid[], text)
to authenticated;

create or replace function private.guard_mail_v2_projection_batch()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.mail_v2_projection_internal', true) <> 'on' then
    raise exception 'MAIL_V2_PROJECTION_MUTATION_DENIED'
      using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    if old.event_count <> 0 then
      raise exception 'MAIL_V2_PROJECTION_DELETE_DENIED'
        using errcode = '55000';
    end if;
    return old;
  end if;
  if old.id is distinct from new.id
    or old.parent_account_id is distinct from new.parent_account_id
    or old.season_id is distinct from new.season_id
    or old.template_key is distinct from new.template_key
    or old.cohort_id is distinct from new.cohort_id
    or old.template_revision_id is distinct from new.template_revision_id
    or old.branding_revision_id is distinct from new.branding_revision_id
    or old.created_at is distinct from new.created_at
  then
    raise exception 'MAIL_V2_PROJECTION_BINDING_IMMUTABLE'
      using errcode = '55000';
  end if;
  if old.event_count is distinct from new.event_count
    and not (
      old.status = 'leased'
      and new.status = 'leased'
      and old.event_count = 0
      and new.event_count between 1 and 100
      and new.lease_token is not distinct from old.lease_token
    )
  then
    raise exception 'MAIL_V2_PROJECTION_EVENT_COUNT_IMMUTABLE'
      using errcode = '55000';
  end if;
  if old.retry_count is distinct from new.retry_count
    and not (
      new.status = 'leased'
      and old.status in ('queued', 'suppressed')
      and new.retry_count = old.retry_count + 1
    )
  then
    raise exception 'MAIL_V2_PROJECTION_RETRY_INVALID'
      using errcode = '55000';
  end if;
  if (
    old.eligible_event_count is distinct from new.eligible_event_count
    or old.eligibility_revision is distinct from new.eligibility_revision
  ) and not (
    (
      old.status = 'leased'
      and new.status = 'queued'
      and new.eligible_event_count between 1 and new.event_count
      and new.eligibility_revision ~ '^[0-9a-f]{64}$'
    )
    or (
      old.status = 'queued'
      and new.status in ('leased', 'suppressed')
      and new.eligible_event_count is null
      and new.eligibility_revision is null
    )
  ) then
    raise exception 'MAIL_V2_PROJECTION_ELIGIBILITY_INVALID'
      using errcode = '55000';
  end if;
  if old.status = 'leased' and new.status = 'leased' then
    if old.lease_expires_at > timezone('utc', now())
      and new.lease_token is distinct from old.lease_token
    then
      raise exception 'MAIL_V2_PROJECTION_LEASE_ACTIVE'
        using errcode = '40001';
    end if;
    return new;
  end if;
  if old.status = 'leased' and new.status in ('queued', 'suppressed') then
    return new;
  end if;
  if old.status = 'queued'
    and new.status in ('leased', 'suppressed')
    and old.email_job_id is not null
    and new.email_job_id is null
  then
    return new;
  end if;
  if old.status = 'suppressed'
    and old.suppression_reason in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
    )
    and new.status = 'leased'
    and new.suppression_reason is null
    and new.email_job_id is null
    and new.retry_count = old.retry_count + 1
  then
    return new;
  end if;
  raise exception 'MAIL_V2_PROJECTION_TRANSITION_INVALID'
    using errcode = '55000';
end;
$$;

revoke all on function private.guard_mail_v2_projection_batch()
from public, anon, authenticated, service_role;

create or replace function private.open_mail_v2_projection_action(
  p_batch private.mail_v2_projection_batches,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
begin
  return private.open_action_item(
    'mail_projection_failed',
    p_batch.season_id,
    'mail_v2_projection_batch',
    p_batch.id,
    'mail_v2_projection',
    p_batch.id,
    encode(
      extensions.digest(
        convert_to('mail-v2-projection:' || p_batch.id::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    'warning',
    'admin_only',
    p_reason,
    jsonb_build_object(
      'batchId',
      p_batch.id,
      'count',
      p_batch.event_count
    ),
    timezone('utc', now()) + interval '1 day'
  );
end;
$$;

revoke all on function private.open_mail_v2_projection_action(
  private.mail_v2_projection_batches,
  text
) from public, anon, authenticated, service_role;

create or replace function app.retry_mail_v2_domain_projection_v1(
  p_projection_batch_id uuid,
  p_expected_retry_count integer,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target private.mail_v2_projection_batches%rowtype;
  normalized_reason text;
  eligible_count integer;
  pending_count integer;
  action_dedupe_key text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_projection_batch_id is null
    or p_expected_retry_count is null
    or p_expected_retry_count not between 0 and 9
    or length(normalized_reason) not between 4 and 500
    or normalized_reason ~ '[[:cntrl:]]'
  then
    raise exception 'MAIL_V2_PROJECTION_RETRY_INPUT_INVALID'
      using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'mail-v2-projection-retry:' || p_projection_batch_id::text,
      0
    )
  );
  select * into target
  from private.mail_v2_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_V2_DOMAIN_PROJECTION_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  if target.retry_count <> p_expected_retry_count then
    raise exception 'MAIL_V2_PROJECTION_RETRY_STALE'
      using errcode = '40001';
  end if;
  if target.status <> 'suppressed'
    or target.suppression_reason not in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
    )
    or target.email_job_id is not null
    or target.retry_count >= 10
    or exists(
      select 1
      from private.mail_v2_projections projection
      join private.mail_v2_event_suppressions suppression
        on suppression.event_id = projection.event_id
      where projection.projection_batch_id = target.id
    )
  then
    raise exception 'MAIL_V2_PROJECTION_RETRY_NOT_ALLOWED'
      using errcode = '55000';
  end if;
  select
    eligibility.eligible_count,
    eligibility.pending_count
  into eligible_count, pending_count
  from private.mail_v2_projection_eligibility(target.id) eligibility;
  if pending_count > 0 or eligible_count = 0 then
    raise exception 'MAIL_V2_PROJECTION_RETRY_NOT_ELIGIBLE'
      using errcode = '55000';
  end if;

  perform set_config('app.mail_v2_projection_internal', 'on', true);
  update private.mail_v2_projection_batches
  set status = 'leased',
      lease_token = gen_random_uuid(),
      lease_expires_at = timezone('utc', now()) - interval '1 second',
      suppression_reason = null,
      retry_count = retry_count + 1,
      updated_at = timezone('utc', now())
  where id = target.id;
  perform set_config('app.mail_v2_projection_internal', 'off', true);

  action_dedupe_key := encode(
    extensions.digest(
      convert_to('mail-v2-projection:' || target.id::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform private.auto_resolve_action_item(
    'mail_projection_failed',
    target.season_id,
    action_dedupe_key,
    normalized_reason
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'mail_v2.domain.retry_requested',
    'mail_v2_projection_batch',
    target.id,
    jsonb_build_object(
      'templateKey',
      target.template_key,
      'retryCount',
      target.retry_count + 1,
      'reasonDigest',
      encode(
        extensions.digest(
          convert_to(normalized_reason, 'UTF8'),
          'sha256'
        ),
        'hex'
      ),
      'reasonLength',
      length(normalized_reason)
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'groupId',
    target.id,
    'status',
    'leased',
    'retryCount',
    target.retry_count + 1
  );
exception when others then
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.retry_mail_v2_domain_projection_v1(
  uuid, integer, text, uuid
) from public, anon, authenticated;
grant execute on function app.retry_mail_v2_domain_projection_v1(
  uuid, integer, text, uuid
) to authenticated;

create or replace function private.mail_v2_cutover_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  catalog_count integer;
  published_count integer;
  branding_count integer;
  producer_count integer;
  legacy_pending_count integer;
  projection_failure_count integer;
  unresolved_confirmation_count integer;
  state_material text;
  state_hash text;
begin
  select count(*)::integer into catalog_count
  from app.mail_templates template
  where template.active;
  select count(*)::integer into published_count
  from app.mail_templates template
  join app.mail_template_revisions revision
    on revision.template_key = template.template_key
    and revision.status = 'published'
    and revision.sanitized_html_source is not null
  where template.active;
  select count(*)::integer into branding_count
  from app.mail_branding_revisions branding
  where branding.status = 'published'
    and branding.contrast_validated;
  select count(*)::integer into producer_count
  from private.mail_v2_process_capabilities capability
  join app.mail_templates template
    on template.template_key = capability.template_key
    and template.active
  where capability.enabled;
  select count(*)::integer into legacy_pending_count
  from private.email_jobs job
  where job.context_kind in ('order', 'portal_access')
    and job.status in (
      'queued',
      'retry',
      'processing',
      'delivery_uncertain'
    );
  select count(*)::integer into projection_failure_count
  from private.mail_v2_projection_batches batch
  where batch.status = 'suppressed'
    and batch.suppression_reason in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid',
      'retry_exhausted'
    );
  select count(*)::integer into unresolved_confirmation_count
  from app.package_size_confirmations confirmation
  where confirmation.package_snapshot_id is null
    or exists(
      select 1
      from app.package_size_confirmation_items confirmation_item
      join app.order_package_snapshot_items snapshot_item
        on snapshot_item.id = confirmation_item.snapshot_item_id
      where confirmation_item.confirmation_id = confirmation.id
        and snapshot_item.snapshot_id <>
          confirmation.package_snapshot_id
    );

  select concat_ws(
    E'\n',
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          template.template_key,
          coalesce(revision.revision::text, 'missing'),
          coalesce(revision.content_hash, 'missing')
        ),
        E'\n'
        order by template.template_key
      )
      from app.mail_templates template
      left join app.mail_template_revisions revision
        on revision.template_key = template.template_key
        and revision.status = 'published'
      where template.active
    ), ''),
    coalesce((
      select concat_ws(
        ':',
        branding.revision::text,
        branding.content_hash
      )
      from app.mail_branding_revisions branding
      where branding.status = 'published'
        and branding.contrast_validated
    ), 'missing'),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          capability.template_key,
          capability.producer_version::text,
          capability.enabled::text
        ),
        E'\n'
        order by capability.template_key
      )
      from private.mail_v2_process_capabilities capability
    ), ''),
    catalog_count::text,
    published_count::text,
    branding_count::text,
    producer_count::text,
    legacy_pending_count::text,
    projection_failure_count::text,
    unresolved_confirmation_count::text
  ) into state_material;
  state_hash := encode(
    extensions.digest(convert_to(state_material, 'UTF8'), 'sha256'),
    'hex'
  );

  return jsonb_build_object(
    'enabled',
    coalesce((
      select flag.enabled
      from app.release_feature_flags flag
      where flag.key = 'mail_templates_v2'
    ), false),
    'cutoverAt',
    (
      select cutover.activated_at
      from private.release_cutovers cutover
      where cutover.key = 'mail_templates_v2'
    ),
    'catalogCount',
    catalog_count,
    'publishedCount',
    published_count,
    'brandingCount',
    branding_count,
    'producerCount',
    producer_count,
    'legacyPendingCount',
    legacy_pending_count,
    'projectionFailureCount',
    projection_failure_count,
    'unresolvedConfirmationCount',
    unresolved_confirmation_count,
    'projectionFailures',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'groupId',
        failure.id,
        'templateKey',
        failure.template_key,
        'retryCount',
        failure.retry_count,
        'eventCount',
        failure.event_count,
        'suppressionReason',
        failure.suppression_reason,
        'createdAt',
        failure.created_at
      ) order by failure.created_at, failure.id)
      from (
        select batch.*
        from private.mail_v2_projection_batches batch
        where batch.status = 'suppressed'
          and batch.suppression_reason in (
            'render_invalid',
            'projection_response_invalid',
            'projection_finalize_invalid',
            'retry_exhausted'
          )
        order by batch.created_at, batch.id
        limit 25
      ) failure
    ), '[]'::jsonb),
    'ready',
    catalog_count = 19
      and published_count = catalog_count
      and branding_count = 1
      and producer_count = catalog_count
      and legacy_pending_count = 0
      and projection_failure_count = 0
      and unresolved_confirmation_count = 0,
    'revision',
    state_hash
  );
end;
$$;

revoke all on function private.mail_v2_cutover_snapshot()
from public, anon, authenticated, service_role;

create or replace function app.activate_mail_templates_v2(
  p_expected_revision text,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  snapshot jsonb;
  normalized_reason text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_expected_revision !~ '^[0-9a-f]{64}$'
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'MAIL_V2_CUTOVER_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  lock table app.release_feature_flags in share row exclusive mode;
  lock table app.mail_template_revisions in share mode;
  lock table app.mail_branding_revisions in share mode;
  lock table private.mail_v2_process_capabilities in share mode;
  lock table private.email_jobs in share mode;
  lock table private.mail_v2_projection_batches in share mode;
  lock table app.package_size_confirmations in share mode;
  snapshot := private.mail_v2_cutover_snapshot();
  if (snapshot->>'enabled')::boolean
    and snapshot->>'cutoverAt' is not null
  then
    return snapshot || jsonb_build_object('reused', true);
  end if;
  if snapshot->>'revision' <> p_expected_revision then
    raise exception 'MAIL_V2_CUTOVER_STALE' using errcode = '40001';
  end if;
  if not (snapshot->>'ready')::boolean then
    raise exception 'MAIL_V2_CUTOVER_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;

  insert into private.release_cutovers(key)
  values('mail_templates_v2')
  on conflict (key) do nothing;
  update app.release_feature_flags
  set enabled = true,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key = 'mail_templates_v2';
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata,
    correlation_id
  ) values (
    actor,
    'release.mail_templates_v2.activated',
    'release_feature_flag',
    jsonb_build_object(
      'revision',
      p_expected_revision,
      'catalogCount',
      (snapshot->>'catalogCount')::integer,
      'publishedCount',
      (snapshot->>'publishedCount')::integer,
      'brandingCount',
      (snapshot->>'brandingCount')::integer,
      'producerCount',
      (snapshot->>'producerCount')::integer,
      'legacyPendingCount',
      (snapshot->>'legacyPendingCount')::integer,
      'projectionFailureCount',
      (snapshot->>'projectionFailureCount')::integer,
      'unresolvedConfirmationCount',
      (snapshot->>'unresolvedConfirmationCount')::integer,
      'reasonDigest',
      encode(
        extensions.digest(convert_to(normalized_reason, 'UTF8'), 'sha256'),
        'hex'
      ),
      'reasonLength',
      length(normalized_reason)
    ),
    p_correlation_id
  );
  return private.mail_v2_cutover_snapshot()
    || jsonb_build_object('reused', false);
end;
$$;

revoke all on function app.activate_mail_templates_v2(
  text, text, uuid
) from public, anon;
grant execute on function app.activate_mail_templates_v2(
  text, text, uuid
) to authenticated;

comment on function app.retry_mail_v2_domain_projection_v1(
  uuid, integer, text, uuid
) is
  'AAL2-admin recovery for deterministic render failures; events and bindings remain immutable.';
comment on function app.process_inventory_allocation_queue(integer) is
  'Allocates queued variants under one durable run cohort for consolidated parent notifications.';

select pg_notify('pgrst', 'reload schema');
