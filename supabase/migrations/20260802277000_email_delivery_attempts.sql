-- SendGrid delivery attempts are first-class immutable identities. HTTP
-- acceptance and signed provider events are related to an attempt, never
-- inferred from mutable job state or webhook arrival order.

create table private.email_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  email_job_id uuid not null
    references private.email_jobs(id) on delete restrict,
  attempt_number integer not null check (attempt_number between 1 and 5),
  claim_token uuid not null,
  claimed_at timestamptz not null,
  legacy_ambiguous boolean not null default false,
  created_at timestamptz not null default statement_timestamp(),
  unique (email_job_id, attempt_number),
  unique (email_job_id, claim_token),
  unique (id, email_job_id)
);

create table private.email_delivery_attempt_outcomes (
  id bigint generated always as identity primary key,
  delivery_attempt_id uuid not null
    references private.email_delivery_attempts(id) on delete restrict,
  stage text not null check (
    stage in ('legacy', 'authorization', 'completion', 'recovery')
  ),
  outcome text not null check (
    outcome in (
      'legacy_queued',
      'legacy_processing',
      'legacy_retry',
      'legacy_sent',
      'legacy_failed',
      'legacy_delivery_uncertain',
      'legacy_superseded',
      'authorized',
      'authorization_denied',
      'sent',
      'retry',
      'failed',
      'delivery_uncertain',
      'recovered_sent',
      'recovered_retry'
    )
  ),
  provider_http_message_id text check (
    provider_http_message_id is null
    or length(btrim(provider_http_message_id)) between 3 and 240
  ),
  error_code text check (
    error_code is null
    or error_code ~ '^[a-z0-9][a-z0-9._-]{0,99}$'
  ),
  actor_user_id uuid
    references app.staff_profiles(auth_user_id) on delete restrict,
  evidence_supplied boolean not null default false,
  created_at timestamptz not null default statement_timestamp()
);

create table private.email_delivery_attempt_provider_messages (
  delivery_attempt_id uuid primary key
    references private.email_delivery_attempts(id) on delete restrict,
  provider_message_id text not null unique check (
    length(btrim(provider_message_id)) between 1 and 240
  ),
  bound_at timestamptz not null default statement_timestamp()
);

create table private.email_provider_event_quarantine (
  id bigint generated always as identity primary key,
  event_fingerprint text not null check (
    event_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  reason text not null check (
    reason in (
      'attempt_identity_missing',
      'attempt_job_mismatch',
      'event_identity_collision',
      'event_message_mismatch',
      'occurred_at_out_of_bounds'
    )
  ),
  email_job_id uuid,
  delivery_attempt_id uuid,
  occurred_at timestamptz,
  recorded_at timestamptz not null default statement_timestamp(),
  unique (event_fingerprint, reason)
);

alter table private.email_delivery_attempts enable row level security;
alter table private.email_delivery_attempt_outcomes enable row level security;
alter table private.email_delivery_attempt_provider_messages
  enable row level security;
alter table private.email_provider_event_quarantine enable row level security;
revoke all on
  private.email_delivery_attempts,
  private.email_delivery_attempt_outcomes,
  private.email_delivery_attempt_provider_messages,
  private.email_provider_event_quarantine
from public, anon, authenticated, service_role;

create or replace function private.reject_email_delivery_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  raise exception 'EMAIL_DELIVERY_LEDGER_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger email_delivery_attempts_immutable
before update or delete on private.email_delivery_attempts
for each row execute function private.reject_email_delivery_ledger_mutation();
create trigger email_delivery_attempt_outcomes_immutable
before update or delete on private.email_delivery_attempt_outcomes
for each row execute function private.reject_email_delivery_ledger_mutation();
create trigger email_delivery_attempt_provider_messages_immutable
before update or delete on private.email_delivery_attempt_provider_messages
for each row execute function private.reject_email_delivery_ledger_mutation();
create trigger email_provider_event_quarantine_immutable
before update or delete on private.email_provider_event_quarantine
for each row execute function private.reject_email_delivery_ledger_mutation();

revoke all on function private.reject_email_delivery_ledger_mutation()
from public, anon, authenticated, service_role;

alter table private.email_jobs
  add column current_delivery_attempt_id uuid,
  add column delivery_event_occurred_at timestamptz,
  add column delivery_event_rank integer check (
    delivery_event_rank is null or delivery_event_rank between 1 and 5
  ),
  add constraint email_jobs_current_delivery_attempt_fkey
    foreign key (current_delivery_attempt_id, id)
    references private.email_delivery_attempts(id, email_job_id)
    on delete restrict;

alter table app.email_events
  add column delivery_attempt_id uuid;

insert into private.email_delivery_attempts(
  email_job_id,
  attempt_number,
  claim_token,
  claimed_at,
  legacy_ambiguous,
  created_at
)
select
  job.id,
  greatest(job.attempts, 1),
  coalesce(job.claim_token, gen_random_uuid()),
  coalesce(job.claimed_at, job.created_at),
  job.attempts > 1
    or (
      select count(distinct provider_event.provider_message_id)
      from app.email_events provider_event
      where provider_event.email_job_id = job.id
    ) > 1,
  coalesce(job.claimed_at, job.created_at)
from private.email_jobs job
where job.attempts > 0
  or job.provider_message_id is not null
  or job.delivery_status is not null
  or exists(
    select 1
    from app.email_events provider_event
    where provider_event.email_job_id = job.id
  );

update private.email_jobs job
set current_delivery_attempt_id = attempt.id
from private.email_delivery_attempts attempt
where attempt.email_job_id = job.id;

update app.email_events provider_event
set delivery_attempt_id = attempt.id
from private.email_delivery_attempts attempt
where attempt.email_job_id = provider_event.email_job_id;

insert into private.email_delivery_attempt_provider_messages(
  delivery_attempt_id,
  provider_message_id,
  bound_at
)
select
  attempt.id,
  min(provider_event.provider_message_id),
  min(provider_event.recorded_at)
from private.email_delivery_attempts attempt
join app.email_events provider_event
  on provider_event.email_job_id = attempt.email_job_id
group by attempt.id
having count(distinct provider_event.provider_message_id) = 1;

alter table app.email_events
  add constraint email_events_delivery_attempt_fkey
    foreign key (delivery_attempt_id, email_job_id)
    references private.email_delivery_attempts(id, email_job_id)
    on delete restrict;

insert into private.email_delivery_attempt_outcomes(
  delivery_attempt_id,
  stage,
  outcome,
  provider_http_message_id,
  error_code,
  created_at
)
select
  attempt.id,
  'legacy',
  'legacy_' || job.status,
  job.provider_message_id,
  case
    when coalesce(job.last_error, '') ~
      '^[a-z0-9][a-z0-9._-]{0,99}$'
    then job.last_error
  end,
  coalesce(job.completed_at, job.updated_at, attempt.claimed_at)
from private.email_delivery_attempts attempt
join private.email_jobs job on job.id = attempt.email_job_id;

with latest as (
  select distinct on (provider_event.delivery_attempt_id)
    provider_event.delivery_attempt_id,
    provider_event.event_type,
    provider_event.occurred_at,
    case provider_event.event_type
      when 'bounced' then 5
      when 'dropped' then 4
      when 'failed' then 3
      when 'delivered' then 2
      else 1
    end event_rank
  from app.email_events provider_event
  order by
    provider_event.delivery_attempt_id,
    provider_event.occurred_at desc,
    case provider_event.event_type
      when 'bounced' then 5
      when 'dropped' then 4
      when 'failed' then 3
      when 'delivered' then 2
      else 1
    end desc,
    provider_event.provider_event_id desc
)
update private.email_jobs job
set delivery_status = latest.event_type,
    delivery_event_occurred_at = latest.occurred_at,
    delivery_event_rank = latest.event_rank
from latest
where job.current_delivery_attempt_id = latest.delivery_attempt_id;

update private.email_jobs job
set status = 'delivery_uncertain',
    uncertain_at = coalesce(job.uncertain_at, statement_timestamp()),
    completed_at = null,
    claim_token = null,
    claimed_at = null,
    last_error = 'legacy_delivery_attempt_ambiguous',
    updated_at = statement_timestamp()
from private.email_delivery_attempts attempt
where attempt.id = job.current_delivery_attempt_id
  and attempt.legacy_ambiguous
  and job.status in ('queued', 'retry', 'processing');

create index email_delivery_attempts_job_idx
  on private.email_delivery_attempts(email_job_id, attempt_number desc);
create index email_delivery_attempt_outcomes_attempt_idx
  on private.email_delivery_attempt_outcomes(delivery_attempt_id, id);
create unique index email_delivery_attempt_outcomes_terminal_stage_idx
  on private.email_delivery_attempt_outcomes(delivery_attempt_id, stage)
  where stage <> 'authorization';
create index email_provider_event_quarantine_recorded_idx
  on private.email_provider_event_quarantine(recorded_at, id);
create index email_events_attempt_occurred_idx
  on app.email_events(
    delivery_attempt_id,
    occurred_at desc,
    provider_event_id desc
  );
create unique index email_delivery_outcomes_provider_http_idx
  on private.email_delivery_attempt_outcomes(provider_http_message_id)
  where provider_http_message_id is not null;

create or replace function app.claim_email_jobs_v4(
  p_claim_token uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  legacy_claim jsonb;
  job_payload jsonb;
  claimed_jobs jsonb := '[]'::jsonb;
  target_job private.email_jobs%rowtype;
  attempt_id uuid;
  next_attempt_number integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;

  update private.email_jobs job
  set status = 'delivery_uncertain',
      uncertain_at = coalesce(job.uncertain_at, statement_timestamp()),
      completed_at = null,
      claim_token = null,
      claimed_at = null,
      last_error = 'legacy_delivery_attempt_ambiguous',
      updated_at = statement_timestamp()
  where job.status in ('queued', 'retry')
    and exists(
      select 1
      from private.email_delivery_attempts attempt
      where attempt.id = job.current_delivery_attempt_id
        and attempt.legacy_ambiguous
    );
  update private.email_jobs job
  set status = 'failed',
      completed_at = statement_timestamp(),
      claim_token = null,
      claimed_at = null,
      last_error = 'delivery_attempts_exhausted',
      updated_at = statement_timestamp()
  where job.status in ('queued', 'retry')
    and (
      select count(*)
      from private.email_delivery_attempts attempt
      where attempt.email_job_id = job.id
    ) >= 5;

  legacy_claim := app.claim_email_jobs_v3(p_claim_token, p_limit);
  for job_payload in
    select value from jsonb_array_elements(legacy_claim->'jobs')
  loop
    select * into target_job
    from private.email_jobs job
    where job.id = (job_payload->>'id')::uuid
      and job.status = 'processing'
      and job.claim_token = p_claim_token
    for update;
    if not found
      or target_job.attempts <> (job_payload->>'attempt')::integer
    then
      raise exception 'EMAIL_DELIVERY_ATTEMPT_CLAIM_CONFLICT'
        using errcode = '40001';
    end if;
    select coalesce(max(attempt.attempt_number), 0) + 1
    into next_attempt_number
    from private.email_delivery_attempts attempt
    where attempt.email_job_id = target_job.id;
    if next_attempt_number > 5 then
      raise exception 'EMAIL_DELIVERY_ATTEMPTS_EXHAUSTED'
        using errcode = '23514';
    end if;

    insert into private.email_delivery_attempts(
      email_job_id,
      attempt_number,
      claim_token,
      claimed_at
    ) values (
      target_job.id,
      next_attempt_number,
      p_claim_token,
      target_job.claimed_at
    )
    returning id into attempt_id;

    update private.email_jobs
    set current_delivery_attempt_id = attempt_id,
        attempts = next_attempt_number
    where id = target_job.id;

    claimed_jobs := claimed_jobs || jsonb_build_array(
      jsonb_set(
        job_payload || jsonb_build_object(
          'deliveryAttemptId',
          attempt_id
        ),
        '{attempt}',
        to_jsonb(next_attempt_number),
        true
      )
    );
  end loop;

  return jsonb_build_object(
    'claimToken',
    p_claim_token,
    'jobs',
    claimed_jobs
  );
end;
$$;

revoke all on function app.claim_email_jobs_v3(uuid, integer)
from service_role;
revoke all on function app.claim_email_jobs_v4(uuid, integer)
from public, anon, authenticated;
grant execute on function app.claim_email_jobs_v4(uuid, integer)
to service_role;

create or replace function app.authorize_claimed_email_job_v4(
  p_job_id uuid,
  p_claim_token uuid,
  p_delivery_attempt_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_job private.email_jobs%rowtype;
  target_attempt private.email_delivery_attempts%rowtype;
  authorized boolean;
begin
  if p_job_id is null
    or p_claim_token is null
    or p_delivery_attempt_id is null
  then
    return false;
  end if;
  select * into target_job
  from private.email_jobs job
  where job.id = p_job_id
    and job.status = 'processing'
    and job.claim_token = p_claim_token
    and job.current_delivery_attempt_id = p_delivery_attempt_id
  for update;
  if not found then
    return false;
  end if;
  select * into target_attempt
  from private.email_delivery_attempts attempt
  where attempt.id = p_delivery_attempt_id
    and attempt.email_job_id = target_job.id
    and attempt.attempt_number = target_job.attempts
    and attempt.claim_token = p_claim_token;
  if not found or target_attempt.legacy_ambiguous then
    return false;
  end if;

  authorized := app.authorize_claimed_email_job_v3(
    p_job_id,
    p_claim_token
  );
  insert into private.email_delivery_attempt_outcomes(
    delivery_attempt_id,
    stage,
    outcome,
    error_code
  ) values (
    target_attempt.id,
    'authorization',
    case when authorized then 'authorized' else 'authorization_denied' end,
    case when authorized then null else 'send_authorization_denied' end
  );
  return authorized;
end;
$$;

revoke all on function app.authorize_claimed_email_job_v3(uuid, uuid)
from service_role;
revoke all on function app.authorize_claimed_email_job_v4(uuid, uuid, uuid)
from public, anon, authenticated;
grant execute on function app.authorize_claimed_email_job_v4(uuid, uuid, uuid)
to service_role;

create or replace function app.complete_email_job_v2(
  p_job_id uuid,
  p_claim_token uuid,
  p_delivery_attempt_id uuid,
  p_outcome text,
  p_provider_message_id text default null,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_job private.email_jobs%rowtype;
  target_attempt private.email_delivery_attempts%rowtype;
  final_status text;
  next_available timestamptz;
  normalized_provider_message_id text :=
    nullif(btrim(p_provider_message_id), '');
  normalized_error text := nullif(left(btrim(p_error), 100), '');
begin
  if p_outcome not in (
    'sent',
    'retry',
    'failed',
    'delivery_uncertain'
  ) then
    raise exception 'INVALID_EMAIL_JOB_OUTCOME' using errcode = '22023';
  end if;
  if p_outcome = 'sent' and (
    normalized_provider_message_id is null
    or length(normalized_provider_message_id) not between 3 and 240
  ) then
    raise exception 'EMAIL_PROVIDER_MESSAGE_REQUIRED'
      using errcode = '22023';
  end if;
  if p_outcome <> 'sent' and normalized_provider_message_id is not null then
    raise exception 'EMAIL_PROVIDER_MESSAGE_NOT_ALLOWED'
      using errcode = '22023';
  end if;
  if normalized_error is not null
    and normalized_error !~ '^[a-z0-9][a-z0-9._-]{0,99}$'
  then
    raise exception 'EMAIL_PROVIDER_ERROR_INVALID' using errcode = '22023';
  end if;

  select * into target_job
  from private.email_jobs job
  where job.id = p_job_id
  for update;
  if not found
    or target_job.current_delivery_attempt_id is distinct from
      p_delivery_attempt_id
  then
    raise exception 'EMAIL_JOB_CLAIM_CONFLICT' using errcode = '40001';
  end if;
  select * into target_attempt
  from private.email_delivery_attempts attempt
  where attempt.id = p_delivery_attempt_id
    and attempt.email_job_id = target_job.id
    and attempt.attempt_number = target_job.attempts
    and attempt.claim_token = p_claim_token;
  if not found or target_attempt.legacy_ambiguous then
    raise exception 'EMAIL_JOB_CLAIM_CONFLICT' using errcode = '40001';
  end if;
  if target_job.provider_message_id is not null
    and normalized_provider_message_id is not null
    and target_job.provider_message_id <> normalized_provider_message_id
  then
    raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT'
      using errcode = '23505';
  end if;

  if target_job.status = 'sent' and exists(
    select 1
    from app.email_events provider_event
    where provider_event.delivery_attempt_id = target_attempt.id
  ) then
    insert into private.email_delivery_attempt_outcomes(
      delivery_attempt_id,
      stage,
      outcome,
      provider_http_message_id,
      error_code
    ) values (
      target_attempt.id,
      'completion',
      p_outcome,
      normalized_provider_message_id,
      normalized_error
    )
    on conflict do nothing;
    if normalized_provider_message_id is not null
      and target_job.provider_message_id is null
    then
      update private.email_jobs
      set provider_message_id = normalized_provider_message_id,
          updated_at = statement_timestamp()
      where id = target_job.id;
    end if;
    return jsonb_build_object(
      'jobId', target_job.id,
      'status', 'sent',
      'attempts', target_job.attempts,
      'availableAt', target_job.available_at
    );
  end if;

  if target_job.status <> 'processing'
    or target_job.claim_token is distinct from p_claim_token
  then
    raise exception 'EMAIL_JOB_CLAIM_CONFLICT' using errcode = '40001';
  end if;

  final_status := case
    when p_outcome = 'retry' and target_job.attempts >= 5 then 'failed'
    else p_outcome
  end;
  next_available := case
    when final_status = 'retry' then statement_timestamp()
      + interval '1 minute'
        * power(2, least(target_job.attempts - 1, 6))
    else target_job.available_at
  end;

  insert into private.email_delivery_attempt_outcomes(
    delivery_attempt_id,
    stage,
    outcome,
    provider_http_message_id,
    error_code
  ) values (
    target_attempt.id,
    'completion',
    final_status,
    normalized_provider_message_id,
    normalized_error
  );

  update private.email_jobs
  set status = final_status,
      provider_message_id = case
        when final_status = 'sent'
        then coalesce(provider_message_id, normalized_provider_message_id)
        else provider_message_id
      end,
      sent_at = case
        when final_status = 'sent'
        then coalesce(sent_at, statement_timestamp())
        else sent_at
      end,
      completed_at = case
        when final_status in ('sent', 'failed')
        then statement_timestamp()
        else null
      end,
      uncertain_at = case
        when final_status = 'delivery_uncertain'
        then statement_timestamp()
        else null
      end,
      available_at = next_available,
      last_error = case
        when final_status = 'sent' then null
        else normalized_error
      end,
      claim_token = null,
      claimed_at = null,
      updated_at = statement_timestamp()
  where id = target_job.id;

  return jsonb_build_object(
    'jobId', target_job.id,
    'status', final_status,
    'attempts', target_job.attempts,
    'availableAt', next_available
  );
exception
  when unique_violation then
    raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT'
      using errcode = '23505';
end;
$$;

revoke all on function app.complete_email_job(
  uuid, uuid, text, text, text
) from service_role;
revoke all on function app.complete_email_job_v2(
  uuid, uuid, uuid, text, text, text
) from public, anon, authenticated;
grant execute on function app.complete_email_job_v2(
  uuid, uuid, uuid, text, text, text
) to service_role;

create or replace function private.quarantine_sendgrid_event_v2(
  p_reason text,
  p_email_job_id uuid,
  p_delivery_attempt_id uuid,
  p_event_id text,
  p_provider_message_id text,
  p_event_type text,
  p_occurred_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = private, extensions, pg_temp
as $$
declare
  fingerprint text;
begin
  if p_reason not in (
    'attempt_identity_missing',
    'attempt_job_mismatch',
    'event_identity_collision',
    'event_message_mismatch',
    'occurred_at_out_of_bounds'
  ) then
    raise exception 'SENDGRID_QUARANTINE_REASON_INVALID'
      using errcode = '22023';
  end if;
  fingerprint := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          coalesce(p_email_job_id::text, ''),
          coalesce(p_delivery_attempt_id::text, ''),
          coalesce(p_event_id, ''),
          coalesce(p_provider_message_id, ''),
          coalesce(p_event_type, ''),
          coalesce(p_occurred_at::text, '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  insert into private.email_provider_event_quarantine(
    event_fingerprint,
    reason,
    email_job_id,
    delivery_attempt_id,
    occurred_at
  ) values (
    fingerprint,
    p_reason,
    p_email_job_id,
    p_delivery_attempt_id,
    p_occurred_at
  )
  on conflict (event_fingerprint, reason) do nothing;
end;
$$;

revoke all on function private.quarantine_sendgrid_event_v2(
  text, uuid, uuid, text, text, text, timestamptz
) from public, anon, authenticated, service_role;

create or replace function private.resolve_email_delivery_failure_v2(
  p_email_job_id uuid,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  resolved_count integer := 0;
begin
  if p_email_job_id is null
    or p_reason is null
    or length(btrim(p_reason)) not between 3 and 120
  then
    raise exception 'EMAIL_FAILURE_RESOLUTION_INVALID'
      using errcode = '22023';
  end if;
  for target in
    select item.season_id, item.dedupe_key
    from app.action_items item
    where item.type = 'email_failure'
      and item.object_type = 'email_job'
      and item.object_id = p_email_job_id
      and item.status in ('open', 'in_progress')
    order by item.id
  loop
    if private.auto_resolve_action_item(
      'email_failure',
      target.season_id,
      target.dedupe_key,
      p_reason
    ) then
      resolved_count := resolved_count + 1;
    end if;
  end loop;
  for target in
    select episode.id
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'internal_email_failure'
      and episode.scope_type = 'email_job'
      and episode.scope_id = p_email_job_id
      and episode.status = 'open'
    order by episode.id
    for update skip locked
  loop
    if private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      'delivery.recovered',
      null,
      'provider_event',
      p_email_job_id,
      null
    ) then
      resolved_count := resolved_count + 1;
    end if;
  end loop;
  return resolved_count;
end;
$$;

revoke all on function private.resolve_email_delivery_failure_v2(uuid, text)
from public, anon, authenticated, service_role;

create or replace function app.record_sendgrid_events_v2(p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  item record;
  target_attempt private.email_delivery_attempts%rowtype;
  target_job private.email_jobs%rowtype;
  existing_event app.email_events%rowtype;
  latest_event record;
  normalized_event_id text;
  normalized_message_id text;
  bound_message_id text;
  inserted_count integer := 0;
  ignored_count integer := 0;
  quarantined_count integer := 0;
  affected integer;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'INVALID_SENDGRID_EVENTS' using errcode = '22023';
  end if;

  for item in
    select *
    from jsonb_to_recordset(p_events) as event_data(
      email_job_id uuid,
      delivery_attempt_id uuid,
      event_id text,
      provider_message_id text,
      event_type text,
      occurred_at timestamptz
    )
  loop
    normalized_event_id := nullif(btrim(item.event_id), '');
    normalized_message_id := nullif(btrim(item.provider_message_id), '');
    if item.email_job_id is null
      or item.delivery_attempt_id is null
      or normalized_event_id is null
      or length(normalized_event_id) > 240
      or normalized_message_id is null
      or length(normalized_message_id) > 240
      or item.occurred_at is null
      or item.event_type not in (
        'delivered',
        'bounced',
        'deferred',
        'dropped',
        'failed'
      )
    then
      perform private.quarantine_sendgrid_event_v2(
        'attempt_identity_missing',
        item.email_job_id,
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    select * into target_attempt
    from private.email_delivery_attempts attempt
    where attempt.id = item.delivery_attempt_id;
    if not found
      or target_attempt.email_job_id <> item.email_job_id
    then
      perform private.quarantine_sendgrid_event_v2(
        'attempt_job_mismatch',
        item.email_job_id,
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;
    if item.occurred_at < target_attempt.claimed_at - interval '5 minutes'
      or item.occurred_at > statement_timestamp() + interval '5 minutes'
    then
      perform private.quarantine_sendgrid_event_v2(
        'occurred_at_out_of_bounds',
        item.email_job_id,
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    existing_event := null;
    select * into existing_event
    from app.email_events provider_event
    where provider_event.provider_event_id = normalized_event_id;
    if existing_event.id is not null then
      if existing_event.email_job_id = item.email_job_id
        and existing_event.delivery_attempt_id = item.delivery_attempt_id
        and existing_event.provider_message_id = normalized_message_id
        and existing_event.event_type = item.event_type
        and existing_event.occurred_at = item.occurred_at
      then
        ignored_count := ignored_count + 1;
      else
        perform private.quarantine_sendgrid_event_v2(
          'event_identity_collision',
          item.email_job_id,
          item.delivery_attempt_id,
          normalized_event_id,
          normalized_message_id,
          item.event_type,
          item.occurred_at
        );
        quarantined_count := quarantined_count + 1;
      end if;
      continue;
    end if;
    insert into private.email_delivery_attempt_provider_messages(
      delivery_attempt_id,
      provider_message_id
    ) values (
      item.delivery_attempt_id,
      normalized_message_id
    )
    on conflict do nothing;
    select binding.provider_message_id into bound_message_id
    from private.email_delivery_attempt_provider_messages binding
    where binding.delivery_attempt_id = item.delivery_attempt_id;
    if bound_message_id is distinct from normalized_message_id then
      perform private.quarantine_sendgrid_event_v2(
        'event_message_mismatch',
        item.email_job_id,
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    insert into app.email_events(
      email_job_id,
      delivery_attempt_id,
      provider_event_id,
      provider_message_id,
      event_type,
      occurred_at
    ) values (
      item.email_job_id,
      item.delivery_attempt_id,
      normalized_event_id,
      normalized_message_id,
      item.event_type,
      item.occurred_at
    )
    on conflict (provider_event_id) do nothing;
    get diagnostics affected = row_count;
    if affected = 0 then
      select * into existing_event
      from app.email_events provider_event
      where provider_event.provider_event_id = normalized_event_id;
      if existing_event.email_job_id = item.email_job_id
        and existing_event.delivery_attempt_id = item.delivery_attempt_id
        and existing_event.provider_message_id = normalized_message_id
        and existing_event.event_type = item.event_type
        and existing_event.occurred_at = item.occurred_at
      then
        ignored_count := ignored_count + 1;
      else
        perform private.quarantine_sendgrid_event_v2(
          'event_identity_collision',
          item.email_job_id,
          item.delivery_attempt_id,
          normalized_event_id,
          normalized_message_id,
          item.event_type,
          item.occurred_at
        );
        quarantined_count := quarantined_count + 1;
      end if;
      continue;
    end if;
    inserted_count := inserted_count + 1;

    select * into target_job
    from private.email_jobs job
    where job.id = item.email_job_id
    for update;
    if target_job.current_delivery_attempt_id is distinct from
      item.delivery_attempt_id
    then
      continue;
    end if;

    select
      provider_event.event_type,
      provider_event.occurred_at,
      case provider_event.event_type
        when 'bounced' then 5
        when 'dropped' then 4
        when 'failed' then 3
        when 'delivered' then 2
        else 1
      end event_rank
    into latest_event
    from app.email_events provider_event
    where provider_event.delivery_attempt_id = item.delivery_attempt_id
    order by
      provider_event.occurred_at desc,
      case provider_event.event_type
        when 'bounced' then 5
        when 'dropped' then 4
        when 'failed' then 3
        when 'delivered' then 2
        else 1
      end desc,
      provider_event.provider_event_id desc
    limit 1;

    update private.email_jobs
    set status = case
          when status in (
            'queued',
            'processing',
            'retry',
            'failed',
            'delivery_uncertain'
          ) then 'sent'
          else status
        end,
        delivery_status = latest_event.event_type,
        delivery_event_occurred_at = latest_event.occurred_at,
        delivery_event_rank = latest_event.event_rank,
        sent_at = coalesce(sent_at, target_attempt.claimed_at),
        completed_at = coalesce(completed_at, statement_timestamp()),
        uncertain_at = null,
        claim_token = null,
        claimed_at = null,
        last_error = null,
        updated_at = statement_timestamp()
    where id = target_job.id;

    if latest_event.event_type not in ('bounced', 'dropped', 'failed') then
      perform private.resolve_email_delivery_failure_v2(
        target_job.id,
        'Providerstatus toont geen definitieve afleverfout.'
      );
    end if;
  end loop;

  return jsonb_build_object(
    'recorded',
    inserted_count,
    'ignored',
    ignored_count,
    'quarantined',
    quarantined_count
  );
end;
$$;

revoke all on function app.record_sendgrid_events(jsonb)
from service_role;
revoke all on function app.record_sendgrid_events_v2(jsonb)
from public, anon, authenticated;
grant execute on function app.record_sendgrid_events_v2(jsonb)
to service_role;

create or replace function app.recover_stale_email_job_v2(
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
  target_attempt private.email_delivery_attempts%rowtype;
  recovered timestamptz := statement_timestamp();
  final_status text;
  normalized_provider_message_id text :=
    nullif(btrim(p_provider_message_id), '');
begin
  if p_job_id is null
    or p_expected_updated_at is null
    or p_resolution not in (
      'confirm_sent',
      'retry_proven_not_accepted'
    )
    or p_reason not in (
      'provider_confirmed_accepted',
      'provider_confirmed_not_accepted'
    )
    or p_provider_evidence_ref is null
    or length(btrim(p_provider_evidence_ref)) not between 8 and 120
    or btrim(p_provider_evidence_ref)
      !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]*$'
  then
    raise exception 'INVALID_EMAIL_RECOVERY' using errcode = '22023';
  end if;
  if p_resolution = 'confirm_sent' and (
    p_reason <> 'provider_confirmed_accepted'
    or normalized_provider_message_id is null
    or length(normalized_provider_message_id) not between 3 and 240
    or p_attested_not_accepted
  ) then
    raise exception 'INVALID_EMAIL_SENT_EVIDENCE' using errcode = '22023';
  end if;
  if p_resolution = 'retry_proven_not_accepted' and (
    p_reason <> 'provider_confirmed_not_accepted'
    or not p_attested_not_accepted
    or normalized_provider_message_id is not null
  ) then
    raise exception 'INVALID_EMAIL_RETRY_EVIDENCE' using errcode = '22023';
  end if;

  select * into target
  from private.email_jobs job
  where job.id = p_job_id
  for update;
  if not found then
    raise exception 'EMAIL_JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.updated_at is distinct from p_expected_updated_at then
    raise exception 'EMAIL_JOB_RECOVERY_CONFLICT' using errcode = '40001';
  end if;
  if not (
    target.status = 'delivery_uncertain'
    or (
      target.status = 'processing'
      and target.claimed_at < recovered - interval '15 minutes'
    )
  ) then
    raise exception 'EMAIL_JOB_NOT_RECOVERABLE' using errcode = '23514';
  end if;
  select * into target_attempt
  from private.email_delivery_attempts attempt
  where attempt.id = target.current_delivery_attempt_id
    and attempt.email_job_id = target.id;
  if not found then
    raise exception 'EMAIL_DELIVERY_ATTEMPT_NOT_FOUND'
      using errcode = '23514';
  end if;
  if p_resolution = 'retry_proven_not_accepted' and (
    target.attempts >= 5
    or exists(
      select 1
      from app.email_events provider_event
      where provider_event.delivery_attempt_id = target_attempt.id
    )
  ) then
    raise exception 'EMAIL_JOB_RETRY_EVIDENCE_CONFLICT'
      using errcode = '23514';
  end if;
  if p_resolution = 'confirm_sent'
    and target.provider_message_id is not null
    and target.provider_message_id <> normalized_provider_message_id
  then
    raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT'
      using errcode = '23505';
  end if;

  final_status := case
    when p_resolution = 'confirm_sent' then 'sent'
    else 'retry'
  end;
  insert into private.email_delivery_attempt_outcomes(
    delivery_attempt_id,
    stage,
    outcome,
    provider_http_message_id,
    actor_user_id,
    evidence_supplied
  ) values (
    target_attempt.id,
    'recovery',
    case
      when final_status = 'sent' then 'recovered_sent'
      else 'recovered_retry'
    end,
    normalized_provider_message_id,
    actor,
    true
  );

  update private.email_jobs
  set status = final_status,
      provider_message_id = case
        when final_status = 'sent'
        then coalesce(provider_message_id, normalized_provider_message_id)
        else provider_message_id
      end,
      sent_at = case
        when final_status = 'sent' then coalesce(sent_at, recovered)
        else sent_at
      end,
      completed_at = case
        when final_status = 'sent' then recovered
        else null
      end,
      available_at = case
        when final_status = 'retry' then recovered
        else available_at
      end,
      uncertain_at = null,
      claim_token = null,
      claimed_at = null,
      last_error = case
        when final_status = 'retry'
        then 'operator_proven_not_accepted'
        else null
      end,
      recovered_at = recovered,
      recovered_by = actor,
      recovery_reason = p_reason,
      recovery_evidence_ref = btrim(p_provider_evidence_ref),
      updated_at = recovered
  where id = target.id;

  perform private.resolve_email_delivery_failure_v2(
    target.id,
    case
      when final_status = 'sent'
      then 'Provideracceptatie is door een beheerder bevestigd.'
      else 'Niet-acceptatie is door een beheerder bevestigd.'
    end
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
    case
      when final_status = 'sent' then 'email.job.recovered.sent'
      else 'email.job.recovered.retry'
    end,
    'email_job',
    target.id,
    jsonb_build_object(
      'resolution',
      p_resolution,
      'reason',
      p_reason,
      'attempts',
      target.attempts,
      'deliveryAttemptId',
      target_attempt.id,
      'provider_evidence_supplied',
      true
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'jobId',
    target.id,
    'status',
    final_status,
    'attempts',
    target.attempts,
    'updatedAt',
    recovered
  );
exception
  when unique_violation then
    raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT'
      using errcode = '23505';
end;
$$;

revoke all on function app.recover_stale_email_job(
  uuid, timestamptz, text, text, text, text, boolean, uuid
) from authenticated;
revoke all on function app.recover_stale_email_job_v2(
  uuid, timestamptz, text, text, text, text, boolean, uuid
) from public, anon;
grant execute on function app.recover_stale_email_job_v2(
  uuid, timestamptz, text, text, text, text, boolean, uuid
) to authenticated;

create or replace function private.produce_internal_email_failure_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_season_id uuid;
  reason text;
  attempt_scope_id uuid := coalesce(
    new.current_delivery_attempt_id,
    new.id
  );
  action_key text;
  event_key text;
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
        and (
          old.delivery_status is distinct from new.delivery_status
          or old.delivery_event_occurred_at is distinct from
            new.delivery_event_occurred_at
        )
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
      convert_to(
        'email-failure-v3:' || attempt_scope_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  event_key := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          'internal-email-failure-v3',
          attempt_scope_id,
          reason,
          coalesce(
            new.delivery_event_occurred_at::text,
            new.updated_at::text
          )
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  perform private.open_action_item(
    'email_failure',
    target_season_id,
    'email_job',
    new.id,
    'email_delivery_attempt',
    attempt_scope_id,
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
    attempt_scope_id,
    'internal-email-failure-v3:' || event_key,
    jsonb_build_object(
      'jobId',
      new.id,
      'deliveryAttemptId',
      attempt_scope_id,
      'reason',
      reason
    )
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

revoke all on function private.produce_internal_email_failure_v2()
from public, anon, authenticated, service_role;

create or replace function app.get_email_workspace_v4()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb := app.get_email_workspace_v3();
  recovery_allowed boolean :=
    app.staff_role() = 'beheerder'
    and coalesce(auth.jwt()->>'aal', '') = 'aal2';
begin
  result := jsonb_set(
    result,
    '{recoveryAllowed}',
    to_jsonb(recovery_allowed),
    true
  );
  if not recovery_allowed then
    result := jsonb_set(
      result,
      '{jobs}',
      coalesce((
        select jsonb_agg(
          jsonb_set(job.value, '{recoverable}', 'false'::jsonb, true)
          order by job.ordinality
        )
        from jsonb_array_elements(result->'jobs')
          with ordinality job(value, ordinality)
      ), '[]'::jsonb),
      true
    );
  end if;
  return result;
end;
$$;

revoke all on function app.get_email_workspace_v4()
from public, anon;
grant execute on function app.get_email_workspace_v4()
to authenticated;

create or replace function app.get_operational_health_v7(
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
  base jsonb := app.get_operational_health_v6(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
begin
  return base || jsonb_build_object(
    'emailDeliveryAttempts',
    jsonb_build_object(
      'legacyAmbiguous',
      (
        select count(*)
        from private.email_delivery_attempts attempt
        where attempt.legacy_ambiguous
      ),
      'quarantinedEvents',
      (
        select count(*)
        from private.email_provider_event_quarantine
      ),
      'unboundLegacyEvents',
      (
        select count(*)
        from app.email_events provider_event
        where provider_event.delivery_attempt_id is null
      ),
      'processingWithoutCurrentAttempt',
      (
        select count(*)
        from private.email_jobs job
        where job.status = 'processing'
          and job.current_delivery_attempt_id is null
      )
    )
  );
end;
$$;

revoke all on function app.get_operational_health_v7(
  text, integer, text, integer
)
from public, anon, authenticated;
grant execute on function app.get_operational_health_v7(
  text, integer, text, integer
)
to service_role;

do $$
declare
  missing_current_attempts bigint;
  mismatched_current_attempts bigint;
  missing_event_attempts bigint;
  impossible_attempt_numbers bigint;
begin
  select count(*) into missing_current_attempts
  from private.email_jobs job
  where (
    job.attempts > 0
    or job.provider_message_id is not null
    or job.delivery_status is not null
    or exists(
      select 1
      from app.email_events provider_event
      where provider_event.email_job_id = job.id
    )
  )
    and job.current_delivery_attempt_id is null;

  select count(*) into mismatched_current_attempts
  from private.email_jobs job
  join private.email_delivery_attempts attempt
    on attempt.id = job.current_delivery_attempt_id
  where attempt.email_job_id <> job.id
    or attempt.attempt_number <> greatest(job.attempts, 1);

  select count(*) into missing_event_attempts
  from app.email_events provider_event
  left join private.email_delivery_attempts attempt
    on attempt.id = provider_event.delivery_attempt_id
    and attempt.email_job_id = provider_event.email_job_id
  where attempt.id is null;

  select count(*) into impossible_attempt_numbers
  from private.email_delivery_attempts attempt
  join private.email_jobs job on job.id = attempt.email_job_id
  where attempt.attempt_number > greatest(job.attempts, 1);

  if missing_current_attempts <> 0
    or mismatched_current_attempts <> 0
    or missing_event_attempts <> 0
    or impossible_attempt_numbers <> 0
  then
    raise exception 'EMAIL_DELIVERY_ATTEMPT_RECONCILIATION_FAILED'
      using errcode = '23514';
  end if;

  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260802277000_email_delivery_attempts',
    'passed',
    jsonb_build_object(
      'attempts', (
        select count(*) from private.email_delivery_attempts
      ),
      'providerEvents', (
        select count(*) from app.email_events
      ),
      'legacyAmbiguous', (
        select count(*)
        from private.email_delivery_attempts
        where legacy_ambiguous
      ),
      'quarantinedEvents', (
        select count(*)
        from private.email_provider_event_quarantine
      )
    )
  )
  on conflict (migration_key) do update
  set status = excluded.status,
      metrics = excluded.metrics,
      reconciled_at = statement_timestamp();
end;
$$;

comment on table private.email_delivery_attempts is
  'Immutable identity for one provider send attempt; custom_args carries this UUID.';
comment on table private.email_provider_event_quarantine is
  'PII-free evidence for signed provider events that cannot be projected safely.';
comment on function app.record_sendgrid_events_v2(jsonb) is
  'Attempt-bound, replay-safe SendGrid event ledger projected by provider occurrence time.';

select pg_notify('pgrst', 'reload schema');
