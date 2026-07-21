alter table private.email_jobs drop constraint email_jobs_status_check;
alter table private.email_jobs
  add constraint email_jobs_status_check
    check (status in ('queued', 'processing', 'retry', 'sent', 'failed', 'delivery_uncertain')),
  add column uncertain_at timestamptz,
  add column recovered_at timestamptz,
  add column recovered_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  add column recovery_reason text,
  add column recovery_evidence_ref text,
  add constraint email_jobs_recovery_reason_check check (
    recovery_reason is null or recovery_reason in ('provider_confirmed_accepted', 'provider_confirmed_not_accepted')
  ),
  add constraint email_jobs_recovery_evidence_check check (
    recovery_evidence_ref is null or (
      length(recovery_evidence_ref) between 8 and 120
      and recovery_evidence_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]*$'
    )
  );

create index email_jobs_uncertain_idx
  on private.email_jobs(uncertain_at, created_at)
  where status = 'delivery_uncertain';

create table private.operation_runs (
  id uuid primary key,
  operation text not null check (operation in ('email_worker', 'retention')),
  status text not null check (status in ('running', 'succeeded', 'failed', 'paused')),
  started_at timestamptz not null default timezone('utc', now()),
  finished_at timestamptz,
  processed_count integer check (processed_count between 0 and 1000000000),
  error_code text check (error_code is null or error_code ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  created_at timestamptz not null default timezone('utc', now()),
  constraint operation_runs_completion_check check (
    (status = 'running' and finished_at is null and processed_count is null and error_code is null)
    or (status in ('succeeded', 'paused') and finished_at is not null and processed_count is not null and error_code is null)
    or (status = 'failed' and finished_at is not null and processed_count is not null and error_code is not null)
  )
);

create index operation_runs_operation_started_idx
  on private.operation_runs(operation, started_at desc);
create index operation_runs_success_idx
  on private.operation_runs(operation, finished_at desc)
  where status = 'succeeded';
create index operation_runs_running_idx
  on private.operation_runs(operation, started_at)
  where status = 'running';
create index operation_runs_retention_idx
  on private.operation_runs(finished_at)
  where status <> 'running';
create index email_events_failures_occurred_idx
  on app.email_events(occurred_at desc)
  where event_type in ('bounced', 'dropped', 'failed');

alter table private.operation_runs enable row level security;
revoke all on private.operation_runs from public, anon, authenticated, service_role;

create or replace function app.start_operation_run(p_operation text, p_run_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare started timestamptz := timezone('utc', now());
begin
  if p_run_id is null or p_operation not in ('email_worker', 'retention') then
    raise exception 'INVALID_OPERATION_RUN' using errcode = '22023';
  end if;

  insert into private.operation_runs(id, operation, status, started_at)
  values(p_run_id, p_operation, 'running', started);

  return jsonb_build_object('runId', p_run_id, 'operation', p_operation, 'startedAt', started);
exception when unique_violation then
  raise exception 'OPERATION_RUN_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.finish_operation_run(
  p_run_id uuid,
  p_status text,
  p_processed_count integer,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare target private.operation_runs%rowtype; finished timestamptz := timezone('utc', now());
begin
  if p_run_id is null or p_status not in ('succeeded', 'failed', 'paused')
    or p_processed_count is null or p_processed_count not between 0 and 1000000000
    or (p_status = 'failed' and (p_error_code is null or p_error_code !~ '^[a-z0-9][a-z0-9._-]{0,63}$'))
    or (p_status <> 'failed' and p_error_code is not null)
  then
    raise exception 'INVALID_OPERATION_RESULT' using errcode = '22023';
  end if;

  select * into target from private.operation_runs
  where id = p_run_id and status = 'running'
  for update;
  if not found then
    raise exception 'OPERATION_RUN_STATE_CONFLICT' using errcode = '40001';
  end if;

  update private.operation_runs
  set status = p_status,
      finished_at = finished,
      processed_count = p_processed_count,
      error_code = p_error_code
  where id = target.id;

  return jsonb_build_object(
    'runId', target.id,
    'operation', target.operation,
    'status', p_status,
    'finishedAt', finished
  );
end;
$$;

create or replace function app.complete_email_job(
  p_job_id uuid, p_claim_token uuid, p_outcome text,
  p_provider_message_id text default null, p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare target_job private.email_jobs%rowtype; final_status text; next_available timestamptz;
begin
  if p_outcome not in ('sent', 'retry', 'failed', 'delivery_uncertain') then
    raise exception 'INVALID_EMAIL_JOB_OUTCOME' using errcode = '22023';
  end if;

  select * into target_job from private.email_jobs where id = p_job_id for update;
  if not found then
    raise exception 'EMAIL_JOB_CLAIM_CONFLICT' using errcode = '40001';
  end if;

  -- A signed SendGrid event can prove provider acceptance before the worker
  -- stores its HTTP result. Treat that race as an idempotent sent outcome.
  if target_job.status = 'sent' and p_outcome in ('sent', 'delivery_uncertain') then
    return jsonb_build_object(
      'jobId', target_job.id,
      'status', 'sent',
      'attempts', target_job.attempts,
      'availableAt', target_job.available_at
    );
  end if;

  if target_job.status <> 'processing' or target_job.claim_token is distinct from p_claim_token then
    raise exception 'EMAIL_JOB_CLAIM_CONFLICT' using errcode = '40001';
  end if;
  if p_outcome = 'sent' and (p_provider_message_id is null or length(trim(p_provider_message_id)) not between 3 and 240) then
    raise exception 'EMAIL_PROVIDER_MESSAGE_REQUIRED' using errcode = '22023';
  end if;
  if p_outcome <> 'sent' and p_provider_message_id is not null then
    raise exception 'EMAIL_PROVIDER_MESSAGE_NOT_ALLOWED' using errcode = '22023';
  end if;

  final_status := case
    when p_outcome = 'retry' and p_error = 'provider_error' then 'delivery_uncertain'
    when p_outcome = 'retry' and target_job.attempts >= 5 then 'failed'
    else p_outcome
  end;
  next_available := case when final_status = 'retry' then timezone('utc', now())
    + interval '1 minute' * power(2, least(target_job.attempts - 1, 6))
    else target_job.available_at end;

  update private.email_jobs
  set status = final_status,
      provider_message_id = case when final_status = 'sent' then trim(p_provider_message_id) else provider_message_id end,
      sent_at = case when final_status = 'sent' then timezone('utc', now()) else sent_at end,
      completed_at = case when final_status in ('sent', 'failed') then timezone('utc', now()) else null end,
      uncertain_at = case when final_status = 'delivery_uncertain' then timezone('utc', now()) else null end,
      available_at = next_available,
      last_error = case when final_status = 'sent' then null else nullif(left(trim(p_error), 1000), '') end,
      claim_token = null,
      claimed_at = null,
      updated_at = timezone('utc', now())
  where id = target_job.id;

  return jsonb_build_object(
    'jobId', target_job.id,
    'status', final_status,
    'attempts', target_job.attempts,
    'availableAt', next_available
  );
exception when unique_violation then
  raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.cleanup_expired_security_data(p_now timestamptz)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  otp_count integer;
  rate_count integer;
  session_count integer;
  email_event_count integer;
begin
  if p_now is null then
    raise exception 'INVALID_RETENTION_TIMESTAMP' using errcode = '22023';
  end if;

  delete from private.parent_otp_challenges challenge
  where challenge.used_at is not null and challenge.used_at <= p_now - interval '24 hours';
  get diagnostics otp_count = row_count;
  with deleted as (
    delete from private.parent_otp_challenges challenge
    where challenge.used_at is null and challenge.expires_at <= p_now - interval '24 hours'
    returning 1
  )
  select otp_count + count(*)::integer into otp_count from deleted;

  delete from private.rate_limit_events event where event.occurred_at < p_now - interval '30 days';
  get diagnostics rate_count = row_count;
  delete from private.parent_sessions session
  where (case when session.revoked_at is not null then session.revoked_at else session.expires_at end)
    <= p_now - interval '30 days';
  get diagnostics session_count = row_count;
  delete from app.email_events event where event.occurred_at < p_now - interval '12 months';
  get diagnostics email_event_count = row_count;
  delete from private.operation_runs run
  where run.status <> 'running' and run.finished_at < p_now - interval '90 days';

  return jsonb_build_object(
    'otpChallenges', otp_count,
    'rateLimitEvents', rate_count,
    'parentSessions', session_count,
    'emailEvents', email_event_count
  );
end;
$$;

create or replace function app.record_sendgrid_events(p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  item record;
  target_job private.email_jobs%rowtype;
  event_provider_message_id text;
  inserted_count integer := 0;
  ignored_count integer := 0;
  affected integer;
begin
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then
    raise exception 'INVALID_SENDGRID_EVENTS' using errcode = '22023';
  end if;

  for item in select * from jsonb_to_recordset(p_events)
    as event_data(email_job_id uuid, event_id text, provider_message_id text, event_type text, occurred_at timestamptz)
  loop
    if item.email_job_id is null or item.event_id is null or item.occurred_at is null
      or item.event_type not in ('delivered', 'bounced', 'deferred', 'dropped', 'failed')
    then
      ignored_count := ignored_count + 1;
      continue;
    end if;

    select * into target_job from private.email_jobs
    where id = item.email_job_id and status in ('sent', 'processing', 'delivery_uncertain')
    for update;
    if not found then
      ignored_count := ignored_count + 1;
      continue;
    end if;

    event_provider_message_id := coalesce(nullif(trim(item.provider_message_id), ''), target_job.provider_message_id);
    if event_provider_message_id is null then
      ignored_count := ignored_count + 1;
      continue;
    end if;

    insert into app.email_events(email_job_id, provider_event_id, provider_message_id, event_type, occurred_at)
    values(target_job.id, left(item.event_id, 240), event_provider_message_id, item.event_type, item.occurred_at)
    on conflict(provider_event_id) do nothing;
    get diagnostics affected = row_count;

    if affected = 1 then
      inserted_count := inserted_count + 1;
      if target_job.status in ('processing', 'delivery_uncertain') then
        update private.email_jobs
        set status = 'sent',
            provider_message_id = coalesce(provider_message_id, event_provider_message_id),
            sent_at = coalesce(sent_at, item.occurred_at),
            completed_at = coalesce(completed_at, timezone('utc', now())),
            delivery_status = item.event_type,
            uncertain_at = null,
            claim_token = null,
            claimed_at = null,
            last_error = null,
            updated_at = timezone('utc', now())
        where id = target_job.id;
      else
        update private.email_jobs
        set delivery_status = item.event_type, updated_at = timezone('utc', now())
        where id = target_job.id;
      end if;
    else
      ignored_count := ignored_count + 1;
    end if;
  end loop;

  return jsonb_build_object('recorded', inserted_count, 'ignored', ignored_count);
end;
$$;

create or replace function app.recover_stale_email_job(
  p_job_id uuid,
  p_expected_updated_at timestamptz,
  p_resolution text,
  p_reason text,
  p_provider_evidence_ref text,
  p_provider_message_id text default null,
  p_attested_not_accepted boolean default false,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target private.email_jobs%rowtype;
  recovered timestamptz := timezone('utc', now());
  final_status text;
begin
  if p_job_id is null or p_expected_updated_at is null
    or p_resolution not in ('confirm_sent', 'retry_proven_not_accepted')
    or p_reason not in ('provider_confirmed_accepted', 'provider_confirmed_not_accepted')
    or p_provider_evidence_ref is null
    or length(trim(p_provider_evidence_ref)) not between 8 and 120
    or trim(p_provider_evidence_ref) !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]*$'
  then
    raise exception 'INVALID_EMAIL_RECOVERY' using errcode = '22023';
  end if;

  if p_resolution = 'confirm_sent' and (
    p_reason <> 'provider_confirmed_accepted'
    or p_provider_message_id is null
    or length(trim(p_provider_message_id)) not between 3 and 240
    or p_attested_not_accepted
  ) then
    raise exception 'INVALID_EMAIL_SENT_EVIDENCE' using errcode = '22023';
  end if;
  if p_resolution = 'retry_proven_not_accepted' and (
    p_reason <> 'provider_confirmed_not_accepted'
    or not p_attested_not_accepted
    or p_provider_message_id is not null
  ) then
    raise exception 'INVALID_EMAIL_RETRY_EVIDENCE' using errcode = '22023';
  end if;

  select * into target from private.email_jobs where id = p_job_id for update;
  if not found then
    raise exception 'EMAIL_JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.updated_at is distinct from p_expected_updated_at then
    raise exception 'EMAIL_JOB_RECOVERY_CONFLICT' using errcode = '40001';
  end if;
  if not (
    target.status = 'delivery_uncertain'
    or (target.status = 'processing' and target.claimed_at < recovered - interval '15 minutes')
  ) then
    raise exception 'EMAIL_JOB_NOT_RECOVERABLE' using errcode = '23514';
  end if;
  if p_resolution = 'retry_proven_not_accepted' and target.attempts >= 5 then
    raise exception 'EMAIL_JOB_ATTEMPTS_EXHAUSTED' using errcode = '23514';
  end if;

  final_status := case when p_resolution = 'confirm_sent' then 'sent' else 'retry' end;
  update private.email_jobs
  set status = final_status,
      provider_message_id = case when final_status = 'sent' then trim(p_provider_message_id) else provider_message_id end,
      sent_at = case when final_status = 'sent' then recovered else sent_at end,
      completed_at = case when final_status = 'sent' then recovered else null end,
      available_at = case when final_status = 'retry' then recovered else available_at end,
      uncertain_at = null,
      claim_token = null,
      claimed_at = null,
      last_error = case when final_status = 'retry' then 'operator_proven_not_accepted' else null end,
      recovered_at = recovered,
      recovered_by = actor,
      recovery_reason = p_reason,
      recovery_evidence_ref = trim(p_provider_evidence_ref),
      updated_at = recovered
  where id = target.id;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(
    actor,
    case when final_status = 'sent' then 'email.job.recovered.sent' else 'email.job.recovered.retry' end,
    'email_job',
    target.id,
    jsonb_build_object(
      'resolution', p_resolution,
      'reason', p_reason,
      'attempts', target.attempts,
      'provider_evidence_supplied', true
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'jobId', target.id,
    'status', final_status,
    'attempts', target.attempts,
    'updatedAt', recovered
  );
exception when unique_violation then
  raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.get_email_workspace_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare role app.staff_role := app.staff_role();
begin
  if role not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'recoveryAllowed', role = 'beheerder',
    'templateKeys', array['verification_code','payment_request','payment_received','ready_for_pickup','payment_reminder','qr_code_resent'],
    'templates', coalesce((select jsonb_agg(jsonb_build_object(
      'id', template.id, 'key', template.template_key, 'subjectSource', template.subject_source,
      'bodySource', template.body_source, 'allowedShortcodes', template.allowed_shortcodes,
      'active', template.active, 'version', template.version, 'updatedAt', template.updated_at
    ) order by template.template_key) from app.email_templates template), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(jsonb_build_object(
      'id', batch.id, 'batchKey', batch.batch_key, 'templateKey', template.template_key,
      'selectedCount', batch.selected_count, 'createdAt', batch.created_at
    ) order by batch.created_at desc)
      from (select * from app.email_batches order by created_at desc limit 25) batch
      join app.email_templates template on template.id = batch.template_id), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object(
      'id', job.id, 'orderId', job.order_id, 'templateKey', job.template_key,
      'status', job.status, 'attempts', job.attempts, 'deliveryStatus', job.delivery_status,
      'availableAt', job.available_at, 'sentAt', job.sent_at, 'createdAt', job.created_at,
      'updatedAt', job.updated_at, 'claimedAt', job.claimed_at,
      'recoverable', role = 'beheerder' and (
        job.status = 'delivery_uncertain'
        or (job.status = 'processing' and job.claimed_at < timezone('utc', now()) - interval '15 minutes')
      )
    ) order by job.created_at desc)
      from (select * from private.email_jobs where order_id is not null order by created_at desc limit 100) job), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object(
      'orderId', orders.id, 'memberName', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'relationNumber', member.relation_number, 'team', member.team, 'season', season.name,
      'amountDueCents', orders.amount_due_cents,
      'paymentReminderEligible', not exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid'),
      'readyForPickupEligible', exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid')
        and exists(select 1 from app.order_lines line where line.order_id = orders.id and line.status = 'ready_for_pickup'),
      'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'orderLineId', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.id)
        from app.order_lines line join app.articles article on article.id = line.article_id
        where line.order_id = orders.id and line.status <> 'cancelled'), '[]'::jsonb)
    ) order by member.last_name, member.first_name)
      from app.member_orders orders
      join app.members member on member.id = orders.member_id and member.active_for_season
      join app.seasons season on season.id = orders.season_id
      join app.app_settings settings on settings.id = true and settings.active_season_id = orders.season_id), '[]'::jsonb)
  );
end;
$$;

create or replace function app.get_operational_health_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := timezone('utc', now());
  email_required boolean := coalesce((select email_enabled from app.app_settings where id = true), false);
  email_latest private.operation_runs%rowtype;
  retention_latest private.operation_runs%rowtype;
  email_last_success timestamptz;
  retention_last_success timestamptz;
begin
  select * into email_latest from private.operation_runs
  where operation = 'email_worker' order by started_at desc limit 1;
  select * into retention_latest from private.operation_runs
  where operation = 'retention' order by started_at desc limit 1;
  select max(finished_at) into email_last_success from private.operation_runs
  where operation = 'email_worker' and status = 'succeeded';
  select max(finished_at) into retention_last_success from private.operation_runs
  where operation = 'retention' and status = 'succeeded';

  return jsonb_build_object(
    'emailJobs', jsonb_build_object(
      'queued', (select count(*) from private.email_jobs where status = 'queued'),
      'retry', (select count(*) from private.email_jobs where status = 'retry'),
      'processingStale', (select count(*) from private.email_jobs
        where status = 'processing' and claimed_at < now_utc - interval '15 minutes'),
      'deliveryUncertain', (select count(*) from private.email_jobs where status = 'delivery_uncertain'),
      'failed', (select count(*) from private.email_jobs where status = 'failed'),
      'oldestPendingAt', (select min(created_at) from private.email_jobs where status in ('queued', 'retry'))
    ),
    'operations', jsonb_build_object(
      'emailWorker', jsonb_build_object(
        'required', email_required,
        'lastStatus', email_latest.status,
        'lastStartedAt', email_latest.started_at,
        'lastSucceededAt', email_last_success,
        'stale', email_required and (email_last_success is null or email_last_success < now_utc - interval '2 minutes'),
        'runningStale', exists(select 1 from private.operation_runs
          where operation = 'email_worker' and status = 'running' and started_at < now_utc - interval '2 minutes')
      ),
      'retention', jsonb_build_object(
        'required', true,
        'lastStatus', retention_latest.status,
        'lastStartedAt', retention_latest.started_at,
        'lastSucceededAt', retention_last_success,
        'stale', retention_last_success is null or retention_last_success < now_utc - interval '26 hours',
        'runningStale', exists(select 1 from private.operation_runs
          where operation = 'retention' and status = 'running' and started_at < now_utc - interval '15 minutes')
      )
    ),
    'recentDeliveryFailures', (
      select count(*) from app.email_events
      where event_type in ('bounced', 'dropped', 'failed') and occurred_at >= now_utc - interval '24 hours'
    ),
    'reconciliationIssues', (
      select count(*) from app.payments where reconciliation_issue is not null
    ),
    'recentWebhookFailures', (
      select count(*) from private.payment_events
      where event_type = 'mismatch' and processed_at >= now_utc - interval '24 hours'
    ),
    'dbTime', to_char(now_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  );
end;
$$;

-- Preserve the exact previous response shapes for a safe app rollback after
-- this migration. The v2 endpoints expose the new operational fields.
create or replace function app.get_email_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare workspace jsonb := app.get_email_workspace_v2(); compatible_jobs jsonb;
begin
  select coalesce(jsonb_agg(
    (job - array['updatedAt', 'claimedAt', 'recoverable'])
    || jsonb_build_object(
      'status', case when job->>'status' = 'delivery_uncertain' then 'failed' else job->>'status' end
    )
    order by ordinal
  ), '[]'::jsonb)
  into compatible_jobs
  from jsonb_array_elements(workspace->'jobs') with ordinality entries(job, ordinal);

  return (workspace - 'recoveryAllowed' - 'jobs') || jsonb_build_object('jobs', compatible_jobs);
end;
$$;

create or replace function app.get_operational_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare health jsonb := app.get_operational_health_v2();
begin
  return jsonb_build_object(
    'emailJobs', jsonb_build_object(
      'queued', (health #>> '{emailJobs,queued}')::integer,
      'retry', (health #>> '{emailJobs,retry}')::integer,
      'processingStale', (health #>> '{emailJobs,processingStale}')::integer,
      'failed', (health #>> '{emailJobs,failed}')::integer + (health #>> '{emailJobs,deliveryUncertain}')::integer
    ),
    'reconciliationIssues', (health->>'reconciliationIssues')::integer,
    'recentWebhookFailures', (health->>'recentWebhookFailures')::integer,
    'dbTime', health->>'dbTime'
  );
end;
$$;

revoke all on function app.start_operation_run(text, uuid) from public, anon, authenticated;
revoke all on function app.finish_operation_run(uuid, text, integer, text) from public, anon, authenticated;
revoke all on function app.cleanup_expired_security_data(timestamptz) from public, anon, authenticated;
revoke all on function app.complete_email_job(uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function app.record_sendgrid_events(jsonb) from public, anon, authenticated;
revoke all on function app.recover_stale_email_job(uuid, timestamptz, text, text, text, text, boolean, uuid) from public, anon;
revoke all on function app.get_email_workspace_v2() from public, anon;
revoke all on function app.get_email_workspace() from public, anon;
revoke all on function app.get_operational_health_v2() from public, anon, authenticated;
revoke all on function app.get_operational_health() from public, anon, authenticated;

grant execute on function app.start_operation_run(text, uuid) to service_role;
grant execute on function app.finish_operation_run(uuid, text, integer, text) to service_role;
grant execute on function app.cleanup_expired_security_data(timestamptz) to service_role;
grant execute on function app.complete_email_job(uuid, uuid, text, text, text) to service_role;
grant execute on function app.record_sendgrid_events(jsonb) to service_role;
grant execute on function app.recover_stale_email_job(uuid, timestamptz, text, text, text, text, boolean, uuid) to authenticated;
grant execute on function app.get_email_workspace_v2() to authenticated;
grant execute on function app.get_email_workspace() to authenticated;
grant execute on function app.get_operational_health_v2() to service_role;
grant execute on function app.get_operational_health() to service_role;

notify pgrst, 'reload schema';
