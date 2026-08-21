-- Provider evidence, historical recipient identities and recipient-level
-- suppression. Existing queues and immutable event ledgers remain canonical.

create table private.email_recipient_identities (
  id uuid primary key default gen_random_uuid(),
  email_normalized text not null unique check (
    email_normalized = lower(btrim(email_normalized))
    and length(email_normalized) between 3 and 254
    and email_normalized ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  created_at timestamptz not null default statement_timestamp()
);

create table private.email_recipient_parent_bindings (
  recipient_identity_id uuid not null
    references private.email_recipient_identities(id) on delete restrict,
  parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  first_seen_at timestamptz not null default statement_timestamp(),
  last_seen_at timestamptz not null default statement_timestamp(),
  primary key (recipient_identity_id, parent_account_id)
);

create table private.email_provider_sync_evidence (
  id bigint generated always as identity primary key,
  delivery_attempt_id uuid,
  parent_otp_delivery_attempt_id uuid,
  provider text not null check (provider in ('smtp', 'sendgrid')),
  provider_state text not null check (provider_state in (
    'provider_accepted',
    'temporary_failure',
    'permanent_rejection',
    'delivery_uncertain',
    'configuration_error',
    'disabled'
  )),
  response_code text check (
    response_code is null or response_code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'
  ),
  enhanced_status_code text check (
    enhanced_status_code is null
    or enhanced_status_code ~ '^[245]\.[0-9]{1,3}\.[0-9]{1,3}$'
  ),
  recipient_failure boolean not null default false,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint email_provider_sync_evidence_attempt_check check (
    (delivery_attempt_id is not null)::integer
      + (parent_otp_delivery_attempt_id is not null)::integer = 1
  ),
  constraint email_provider_sync_evidence_general_fkey
    foreign key (delivery_attempt_id)
    references private.email_delivery_attempts(id) on delete restrict,
  constraint email_provider_sync_evidence_parent_fkey
    foreign key (parent_otp_delivery_attempt_id)
    references private.parent_otp_delivery_attempts(id) on delete restrict
);

create unique index email_provider_sync_evidence_general_idx
  on private.email_provider_sync_evidence(delivery_attempt_id)
  where delivery_attempt_id is not null;
create unique index email_provider_sync_evidence_parent_idx
  on private.email_provider_sync_evidence(parent_otp_delivery_attempt_id)
  where parent_otp_delivery_attempt_id is not null;

create table private.email_recipient_suppressions (
  id uuid primary key default gen_random_uuid(),
  recipient_identity_id uuid not null
    references private.email_recipient_identities(id) on delete restrict,
  reason text not null check (reason in (
    'hard_bounce',
    'permanent_recipient_rejection',
    'complaint'
  )),
  evidence_kind text not null check (evidence_kind in (
    'sendgrid_event',
    'smtp_response',
    'parent_otp_provider_event'
  )),
  evidence_reference text not null check (
    evidence_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,239}$'
  ),
  source_job_id uuid references private.email_jobs(id) on delete restrict,
  source_parent_otp_attempt_id uuid
    references private.parent_otp_delivery_attempts(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  lifted_at timestamptz,
  lifted_by uuid,
  lift_reason text,
  constraint email_recipient_suppressions_lift_check check (
    (lifted_at is null and lifted_by is null and lift_reason is null)
    or (
      lifted_at is not null and lifted_by is not null
      and length(btrim(lift_reason)) between 3 and 500
    )
  )
);

create unique index email_recipient_one_active_suppression_idx
  on private.email_recipient_suppressions(recipient_identity_id)
  where lifted_at is null;
create index email_recipient_suppressions_history_idx
  on private.email_recipient_suppressions(
    recipient_identity_id,
    created_at desc
  );
create index email_jobs_recipient_normalized_idx
  on private.email_jobs(lower(btrim(recipient_email)), created_at desc);

alter table private.email_recipient_identities enable row level security;
alter table private.email_recipient_parent_bindings enable row level security;
alter table private.email_provider_sync_evidence enable row level security;
alter table private.email_recipient_suppressions enable row level security;
revoke all on
  private.email_recipient_identities,
  private.email_recipient_parent_bindings,
  private.email_provider_sync_evidence,
  private.email_recipient_suppressions
from public, anon, authenticated, service_role;
revoke all on all sequences in schema private
from public, anon, authenticated, service_role;

create or replace function private.ensure_email_recipient_identity(
  p_email text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = private, pg_temp
as $$
declare
  normalized text := lower(nullif(btrim(p_email), ''));
  result uuid;
begin
  if normalized is null
    or length(normalized) not between 3 and 254
    or normalized !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception 'EMAIL_RECIPIENT_IDENTITY_INVALID' using errcode = '22023';
  end if;
  insert into private.email_recipient_identities(email_normalized)
  values(normalized)
  on conflict (email_normalized) do update
    set email_normalized = excluded.email_normalized
  returning id into result;
  return result;
end;
$$;

revoke all on function private.ensure_email_recipient_identity(text)
from public, anon, authenticated, service_role;

create or replace function private.bind_email_job_recipient_identity()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  perform private.ensure_email_recipient_identity(new.recipient_email);
  return new;
end;
$$;

create trigger email_jobs_00_bind_recipient_identity
before insert on private.email_jobs
for each row execute function private.bind_email_job_recipient_identity();

revoke all on function private.bind_email_job_recipient_identity()
from public, anon, authenticated, service_role;

insert into private.email_recipient_identities(email_normalized)
select distinct lower(btrim(job.recipient_email))
from private.email_jobs job
where job.recipient_email is not null
  and lower(btrim(job.recipient_email))
    ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
union
select account.email_normalized
from private.parent_accounts account
on conflict (email_normalized) do nothing;

alter table private.parent_otp_delivery_attempts
  add column recipient_identity_id uuid
    references private.email_recipient_identities(id) on delete restrict;

update private.parent_otp_delivery_attempts attempt
set recipient_identity_id = identity_row.id
from private.parent_accounts account
join private.email_recipient_identities identity_row
  on identity_row.email_normalized = account.email_normalized
where account.id = attempt.parent_account_id;

alter table private.parent_otp_delivery_attempts
  alter column recipient_identity_id set not null;

insert into private.email_recipient_parent_bindings(
  recipient_identity_id,
  parent_account_id,
  first_seen_at,
  last_seen_at
)
select
  attempt.recipient_identity_id,
  attempt.parent_account_id,
  min(attempt.created_at),
  max(attempt.created_at)
from private.parent_otp_delivery_attempts attempt
group by attempt.recipient_identity_id, attempt.parent_account_id
on conflict (recipient_identity_id, parent_account_id) do update
set first_seen_at = least(
      private.email_recipient_parent_bindings.first_seen_at,
      excluded.first_seen_at
    ),
    last_seen_at = greatest(
      private.email_recipient_parent_bindings.last_seen_at,
      excluded.last_seen_at
    );

create or replace function private.bind_parent_otp_recipient_identity()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  target_email text;
begin
  select account.email_normalized into target_email
  from private.parent_accounts account
  where account.id = new.parent_account_id;
  if target_email is null then
    raise exception 'PARENT_OTP_RECIPIENT_IDENTITY_MISSING'
      using errcode = '23514';
  end if;
  new.recipient_identity_id := private.ensure_email_recipient_identity(
    target_email
  );
  insert into private.email_recipient_parent_bindings(
    recipient_identity_id,
    parent_account_id
  ) values (
    new.recipient_identity_id,
    new.parent_account_id
  )
  on conflict (recipient_identity_id, parent_account_id) do update
  set last_seen_at = statement_timestamp();
  return new;
end;
$$;

create trigger parent_otp_bind_recipient_identity
before insert on private.parent_otp_delivery_attempts
for each row execute function private.bind_parent_otp_recipient_identity();

revoke all on function private.bind_parent_otp_recipient_identity()
from public, anon, authenticated, service_role;

create or replace function private.open_email_recipient_suppression(
  p_recipient_identity_id uuid,
  p_reason text,
  p_evidence_kind text,
  p_evidence_reference text,
  p_source_job_id uuid default null,
  p_source_parent_otp_attempt_id uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  result uuid;
  active_season_id uuid;
  dedupe text;
begin
  insert into private.email_recipient_suppressions(
    recipient_identity_id,
    reason,
    evidence_kind,
    evidence_reference,
    source_job_id,
    source_parent_otp_attempt_id
  ) values (
    p_recipient_identity_id,
    p_reason,
    p_evidence_kind,
    p_evidence_reference,
    p_source_job_id,
    p_source_parent_otp_attempt_id
  )
  on conflict (recipient_identity_id) where lifted_at is null do update
  set evidence_kind = excluded.evidence_kind,
      evidence_reference = excluded.evidence_reference,
      source_job_id = coalesce(excluded.source_job_id,
        private.email_recipient_suppressions.source_job_id),
      source_parent_otp_attempt_id = coalesce(
        excluded.source_parent_otp_attempt_id,
        private.email_recipient_suppressions.source_parent_otp_attempt_id
      )
  returning id into result;
  select settings.active_season_id into active_season_id
  from app.app_settings settings
  where settings.id = true;
  if active_season_id is not null then
    dedupe := encode(extensions.digest(
      p_recipient_identity_id::text || ':email-recipient-permanent-failure',
      'sha256'
    ), 'hex');
    perform private.open_action_item(
      'email_recipient_failure',
      active_season_id,
      'email_recipient',
      p_recipient_identity_id,
      'email_delivery',
      coalesce(p_source_job_id, p_source_parent_otp_attempt_id),
      dedupe,
      'warning',
      'operations',
      case when p_reason = 'hard_bounce'
        then 'email.hard_bounce'
        else 'email.permanent_rejection'
      end,
      jsonb_build_object('count', 1),
      statement_timestamp() + interval '1 day'
    );
  end if;
  return result;
end;
$$;

revoke all on function private.open_email_recipient_suppression(
  uuid, text, text, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.capture_email_bounce_suppression()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  recipient_id uuid;
  job_id uuid;
begin
  if tg_table_schema = 'app' and tg_table_name = 'email_events' then
    if new.event_type <> 'bounced' then return new; end if;
    select job.id,
      private.ensure_email_recipient_identity(job.recipient_email)
    into job_id, recipient_id
    from private.email_jobs job
    where job.id = new.email_job_id;
    perform private.open_email_recipient_suppression(
      recipient_id,
      'hard_bounce',
      'sendgrid_event',
      'event:' || new.id::text,
      job_id,
      null
    );
  else
    if new.event_type <> 'bounced' then return new; end if;
    select attempt.recipient_identity_id into recipient_id
    from private.parent_otp_delivery_attempts attempt
    where attempt.id = new.delivery_attempt_id;
    perform private.open_email_recipient_suppression(
      recipient_id,
      'hard_bounce',
      'parent_otp_provider_event',
      'otp-event:' || new.id::text,
      null,
      new.delivery_attempt_id
    );
  end if;
  return new;
end;
$$;

create trigger email_events_recipient_suppression
after insert on app.email_events
for each row execute function private.capture_email_bounce_suppression();
create trigger parent_otp_events_recipient_suppression
after insert on private.parent_otp_provider_events
for each row execute function private.capture_email_bounce_suppression();

revoke all on function private.capture_email_bounce_suppression()
from public, anon, authenticated, service_role;

-- Historical backfill is deliberately limited to explicit bounce evidence.
select private.open_email_recipient_suppression(
  identity_row.id,
  'hard_bounce',
  'sendgrid_event',
  'event:' || event.id::text,
  job.id,
  null
)
from app.email_events event
join private.email_jobs job on job.id = event.email_job_id
join private.email_recipient_identities identity_row
  on identity_row.email_normalized = lower(btrim(job.recipient_email))
where event.event_type = 'bounced'
order by event.occurred_at, event.id;

select private.open_email_recipient_suppression(
  attempt.recipient_identity_id,
  'hard_bounce',
  'parent_otp_provider_event',
  'otp-event:' || event.id::text,
  null,
  attempt.id
)
from private.parent_otp_provider_events event
join private.parent_otp_delivery_attempts attempt
  on attempt.id = event.delivery_attempt_id
where event.event_type = 'bounced'
order by event.occurred_at, event.id;

create or replace function private.smtp_permanent_recipient_address_status(
  p_enhanced_status_code text
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(p_enhanced_status_code = any(array[
    '5.1.1', '5.1.2', '5.1.3', '5.1.6', '5.1.10'
  ]), false);
$$;

revoke all on function private.smtp_permanent_recipient_address_status(text)
from public, anon, authenticated, service_role;

create or replace function app.complete_email_job_v3(
  p_job_id uuid,
  p_claim_token uuid,
  p_delivery_attempt_id uuid,
  p_outcome text,
  p_provider_message_id text default null,
  p_error text default null,
  p_provider text default null,
  p_provider_state text default null,
  p_response_code text default null,
  p_enhanced_status_code text default null,
  p_recipient_failure boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  identity_id uuid;
  evidence_id bigint;
begin
  if p_provider not in ('smtp', 'sendgrid')
    or p_provider_state not in (
      'provider_accepted', 'temporary_failure', 'permanent_rejection',
      'delivery_uncertain', 'configuration_error', 'disabled'
    )
    or p_recipient_failure is null
    or (
      p_recipient_failure
      and p_provider = 'smtp'
      and (
        p_provider_state <> 'permanent_rejection'
        or not private.smtp_permanent_recipient_address_status(
          nullif(btrim(p_enhanced_status_code), '')
        )
      )
    )
  then
    raise exception 'EMAIL_PROVIDER_EVIDENCE_INVALID' using errcode = '22023';
  end if;
  result := app.complete_email_job_v2(
    p_job_id,
    p_claim_token,
    p_delivery_attempt_id,
    p_outcome,
    p_provider_message_id,
    p_error
  );
  insert into private.email_provider_sync_evidence(
    delivery_attempt_id,
    provider,
    provider_state,
    response_code,
    enhanced_status_code,
    recipient_failure
  ) values (
    p_delivery_attempt_id,
    p_provider,
    p_provider_state,
    nullif(btrim(p_response_code), ''),
    nullif(btrim(p_enhanced_status_code), ''),
    p_recipient_failure
  ) on conflict (delivery_attempt_id)
    where delivery_attempt_id is not null do nothing
  returning id into evidence_id;
  if evidence_id is null and not exists(
    select 1
    from private.email_provider_sync_evidence evidence
    where evidence.delivery_attempt_id = p_delivery_attempt_id
      and evidence.provider = p_provider
      and evidence.provider_state = p_provider_state
      and evidence.response_code is not distinct from nullif(btrim(p_response_code), '')
      and evidence.enhanced_status_code is not distinct from
        nullif(btrim(p_enhanced_status_code), '')
      and evidence.recipient_failure = p_recipient_failure
  ) then
    raise exception 'EMAIL_PROVIDER_EVIDENCE_CONFLICT' using errcode = '23505';
  end if;
  if p_provider_state = 'permanent_rejection' and p_recipient_failure then
    select private.ensure_email_recipient_identity(job.recipient_email)
    into identity_id
    from private.email_jobs job
    where job.id = p_job_id;
    perform private.open_email_recipient_suppression(
      identity_id,
      'permanent_recipient_rejection',
      'smtp_response',
      'attempt:' || p_delivery_attempt_id::text,
      p_job_id,
      null
    );
  end if;
  return result;
end;
$$;

revoke all on function app.complete_email_job_v3(
  uuid, uuid, uuid, text, text, text, text, text, text, text, boolean
) from public, anon, authenticated;
grant execute on function app.complete_email_job_v3(
  uuid, uuid, uuid, text, text, text, text, text, text, text, boolean
) to service_role;

create or replace function app.complete_parent_otp_delivery_v2(
  p_delivery_attempt_id uuid,
  p_outcome text,
  p_provider_http_message_id text default null,
  p_error_code text default null,
  p_provider text default null,
  p_provider_state text default null,
  p_response_code text default null,
  p_enhanced_status_code text default null,
  p_recipient_failure boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  attempt private.parent_otp_delivery_attempts%rowtype;
  evidence_id bigint;
begin
  if p_provider not in ('smtp', 'sendgrid')
    or p_provider_state not in (
      'provider_accepted', 'temporary_failure', 'permanent_rejection',
      'delivery_uncertain', 'configuration_error', 'disabled'
    )
    or p_recipient_failure is null
    or (
      p_recipient_failure
      and p_provider = 'smtp'
      and (
        p_provider_state <> 'permanent_rejection'
        or not private.smtp_permanent_recipient_address_status(
          nullif(btrim(p_enhanced_status_code), '')
        )
      )
    )
  then
    raise exception 'PARENT_OTP_PROVIDER_EVIDENCE_INVALID'
      using errcode = '22023';
  end if;
  result := app.complete_parent_otp_delivery_v1(
    p_delivery_attempt_id,
    p_outcome,
    p_provider_http_message_id,
    p_error_code
  );
  insert into private.email_provider_sync_evidence(
    parent_otp_delivery_attempt_id,
    provider,
    provider_state,
    response_code,
    enhanced_status_code,
    recipient_failure
  ) values (
    p_delivery_attempt_id,
    p_provider,
    p_provider_state,
    nullif(btrim(p_response_code), ''),
    nullif(btrim(p_enhanced_status_code), ''),
    p_recipient_failure
  ) on conflict (parent_otp_delivery_attempt_id)
    where parent_otp_delivery_attempt_id is not null do nothing
  returning id into evidence_id;
  if evidence_id is null and not exists(
    select 1
    from private.email_provider_sync_evidence evidence
    where evidence.parent_otp_delivery_attempt_id = p_delivery_attempt_id
      and evidence.provider = p_provider
      and evidence.provider_state = p_provider_state
      and evidence.response_code is not distinct from nullif(btrim(p_response_code), '')
      and evidence.enhanced_status_code is not distinct from
        nullif(btrim(p_enhanced_status_code), '')
      and evidence.recipient_failure = p_recipient_failure
  ) then
    raise exception 'PARENT_OTP_PROVIDER_EVIDENCE_CONFLICT'
      using errcode = '23505';
  end if;
  if p_provider_state = 'permanent_rejection' and p_recipient_failure then
    select target.* into attempt
    from private.parent_otp_delivery_attempts target
    where target.id = p_delivery_attempt_id;
    perform private.open_email_recipient_suppression(
      attempt.recipient_identity_id,
      'permanent_recipient_rejection',
      'smtp_response',
      'otp-attempt:' || p_delivery_attempt_id::text,
      null,
      p_delivery_attempt_id
    );
  end if;
  return result;
end;
$$;

revoke all on function app.complete_parent_otp_delivery_v2(
  uuid, text, text, text, text, text, text, text, boolean
) from public, anon, authenticated;
grant execute on function app.complete_parent_otp_delivery_v2(
  uuid, text, text, text, text, text, text, text, boolean
) to service_role;

create or replace function app.resolve_parent_otp_delivery_recipient_v1(
  p_delivery_attempt_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select identity_row.email_normalized
  from private.parent_otp_delivery_attempts attempt
  join private.email_recipient_identities identity_row
    on identity_row.id = attempt.recipient_identity_id
  join private.parent_otp_challenges challenge
    on challenge.id = attempt.challenge_id
    and challenge.parent_account_id = attempt.parent_account_id
  where attempt.id = p_delivery_attempt_id
    and attempt.expires_at > statement_timestamp()
    and challenge.closed_at is null
    and challenge.used_at is null
    and challenge.attempts < challenge.max_attempts
    and not exists(
      select 1
      from private.parent_otp_delivery_outcomes outcome
      where outcome.delivery_attempt_id = attempt.id
    );
$$;

revoke all on function app.resolve_parent_otp_delivery_recipient_v1(uuid)
from public, anon, authenticated;
grant execute on function app.resolve_parent_otp_delivery_recipient_v1(uuid)
to service_role;

create or replace function private.email_domain_suspicious(p_email text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select lower(split_part(p_email, '@', 2)) = any(array[
    'gmail.con', 'gmal.com', 'gmial.com', 'hotmai.com',
    'hotmal.com', 'outlok.com', 'outllok.com'
  ]);
$$;

revoke all on function private.email_domain_suspicious(text)
from public, anon, authenticated, service_role;

create or replace function app.get_email_control_center_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  role_name app.staff_role := app.staff_role();
  recipients jsonb;
begin
  with job_stats as (
    select
      identity_row.id recipient_id,
      max(job.created_at) last_send_at,
      max(job.sent_at) filter (where job.status = 'sent') last_accepted_at,
      count(*) filter (where job.status = 'sent') accepted_count,
      count(*) filter (where job.status = 'retry') temporary_count,
      count(*) filter (where job.status = 'delivery_uncertain') uncertain_count,
      max(job.updated_at) filter (
        where job.status in ('failed', 'delivery_uncertain', 'retry')
      ) last_failure_at
    from private.email_recipient_identities identity_row
    join private.email_jobs job
      on lower(btrim(job.recipient_email)) = identity_row.email_normalized
    group by identity_row.id
  ), event_stats as (
    select
      identity_row.id recipient_id,
      max(event.occurred_at) filter (
        where event.event_type = 'delivered'
      ) last_delivered_at,
      max(event.recorded_at) last_feedback_at,
      count(*) filter (where event.event_type = 'bounced') bounce_count,
      count(*) filter (where event.event_type = 'dropped') drop_count,
      count(*) filter (where event.event_type = 'deferred') deferred_count
    from private.email_recipient_identities identity_row
    join private.email_jobs job
      on lower(btrim(job.recipient_email)) = identity_row.email_normalized
    join app.email_events event on event.email_job_id = job.id
    group by identity_row.id
  ), sync_stats as (
    select
      identity_row.id recipient_id,
      count(*) filter (
        where evidence.provider_state = 'temporary_failure'
      ) temporary_count,
      count(*) filter (
        where evidence.provider_state = 'permanent_rejection'
      ) permanent_count,
      count(*) filter (
        where evidence.provider_state = 'delivery_uncertain'
      ) uncertain_count
    from private.email_recipient_identities identity_row
    join private.email_jobs job
      on lower(btrim(job.recipient_email)) = identity_row.email_normalized
    join private.email_delivery_attempts attempt
      on attempt.email_job_id = job.id
    join private.email_provider_sync_evidence evidence
      on evidence.delivery_attempt_id = attempt.id
    group by identity_row.id
  ), otp_stats as (
    select
      attempt.recipient_identity_id recipient_id,
      max(attempt.created_at) last_otp_requested_at,
      max(outcome.created_at) filter (
        where outcome.outcome = 'accepted'
      ) last_otp_accepted_at,
      (array_agg(
        case when outcome.outcome = 'accepted'
          then 'provider_accepted' else outcome.outcome end
        order by attempt.created_at desc
      ))[1] last_otp_outcome,
      max(challenge.expires_at) filter (
        where challenge.closed_at is null
          and challenge.used_at is null
          and challenge.expires_at > statement_timestamp()
          and challenge.attempts < challenge.max_attempts
      ) otp_expires_at,
      count(*) filter (where outcome.outcome = 'accepted') accepted_count,
      count(*) filter (
        where outcome.outcome = 'delivery_uncertain'
      ) uncertain_count
    from private.parent_otp_delivery_attempts attempt
    left join private.parent_otp_delivery_outcomes outcome
      on outcome.delivery_attempt_id = attempt.id
    left join private.parent_otp_challenges challenge
      on challenge.id = attempt.challenge_id
    group by attempt.recipient_identity_id
  ), otp_event_stats as (
    select
      attempt.recipient_identity_id recipient_id,
      max(event.occurred_at) filter (
        where event.event_type = 'delivered'
      ) last_delivered_at,
      max(event.recorded_at) last_feedback_at,
      count(*) filter (where event.event_type = 'bounced') bounce_count,
      count(*) filter (where event.event_type = 'dropped') drop_count,
      count(*) filter (where event.event_type = 'deferred') deferred_count
    from private.parent_otp_delivery_attempts attempt
    join private.parent_otp_provider_events event
      on event.delivery_attempt_id = attempt.id
    group by attempt.recipient_identity_id
  ), rows as (
    select
      identity_row.id,
      identity_row.email_normalized,
      private.email_domain_suspicious(identity_row.email_normalized)
        suspicious_domain,
      suppression.id is not null suppressed,
      suppression.reason suppression_reason,
      greatest(job.last_send_at, otp.last_otp_requested_at) last_send_at,
      greatest(job.last_accepted_at, otp.last_otp_accepted_at)
        last_accepted_at,
      greatest(event.last_delivered_at, otp_event.last_delivered_at)
        last_delivered_at,
      greatest(event.last_feedback_at, otp_event.last_feedback_at)
        last_feedback_at,
      greatest(job.last_failure_at, event.last_feedback_at,
        otp_event.last_feedback_at) last_failure_at,
      coalesce(job.temporary_count, 0)
        + coalesce(sync_row.temporary_count, 0)
        + coalesce(event.deferred_count, 0)
        + coalesce(otp_event.deferred_count, 0) temporary_count,
      coalesce(sync_row.permanent_count, 0) permanent_count,
      coalesce(event.bounce_count, 0)
        + coalesce(otp_event.bounce_count, 0) bounce_count,
      coalesce(event.drop_count, 0)
        + coalesce(otp_event.drop_count, 0) drop_count,
      coalesce(job.uncertain_count, 0)
        + coalesce(sync_row.uncertain_count, 0)
        + coalesce(otp.uncertain_count, 0) uncertain_count,
      coalesce(job.accepted_count, 0)
        + coalesce(otp.accepted_count, 0) accepted_count,
      otp.last_otp_requested_at,
      otp.last_otp_outcome,
      otp.otp_expires_at
    from private.email_recipient_identities identity_row
    left join job_stats job on job.recipient_id = identity_row.id
    left join event_stats event on event.recipient_id = identity_row.id
    left join sync_stats sync_row on sync_row.recipient_id = identity_row.id
    left join otp_stats otp on otp.recipient_id = identity_row.id
    left join otp_event_stats otp_event
      on otp_event.recipient_id = identity_row.id
    left join private.email_recipient_suppressions suppression
      on suppression.recipient_identity_id = identity_row.id
      and suppression.lifted_at is null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', row_data.id,
    'email', case when role_name = 'beheerder'
      then row_data.email_normalized else null end,
    'emailMasked', left(split_part(row_data.email_normalized, '@', 1), 1)
      || repeat('*', greatest(3,
        length(split_part(row_data.email_normalized, '@', 1)) - 1))
      || '@' || split_part(row_data.email_normalized, '@', 2),
    'healthState', case
      when row_data.suppressed then 'suppressed'
      when row_data.bounce_count > 0 or row_data.permanent_count > 0
        or row_data.drop_count > 0 then 'invalid_or_bounce'
      when row_data.temporary_count > 0 or row_data.uncertain_count > 0
        or row_data.suspicious_domain then 'attention'
      when row_data.last_delivered_at is not null then 'healthy'
      when row_data.accepted_count > 0 then 'accepted'
      else 'unknown'
    end,
    'suspiciousDomain', row_data.suspicious_domain,
    'suppressionReason', row_data.suppression_reason,
    'lastSendAt', row_data.last_send_at,
    'lastProviderAcceptanceAt', row_data.last_accepted_at,
    'lastProvenDeliveryAt', row_data.last_delivered_at,
    'lastFailureAt', row_data.last_failure_at,
    'lastProviderFeedbackAt', row_data.last_feedback_at,
    'temporaryFailureCount', row_data.temporary_count,
    'permanentRejectionCount', row_data.permanent_count,
    'hardBounceCount', row_data.bounce_count,
    'dropCount', row_data.drop_count,
    'deliveryUncertainCount', row_data.uncertain_count,
    'lastOtpRequestedAt', row_data.last_otp_requested_at,
    'lastOtpOutcome', row_data.last_otp_outcome,
    'otpExpiresAt', row_data.otp_expires_at,
    'linkedChildren', coalesce((
      select jsonb_agg(child_data.value order by child_data.name)
      from (
        select distinct
          concat_ws(' ', member.first_name, member.insertion,
            member.last_name) name,
          jsonb_build_object(
            'memberId', member.id,
            'memberName', concat_ws(' ', member.first_name,
              member.insertion, member.last_name),
            'team', coalesce(member_season.team_name, 'Onbekend team')
          ) value
        from private.email_recipient_parent_bindings binding
        join private.parent_accounts account
          on account.id = binding.parent_account_id
          and account.email_normalized = row_data.email_normalized
        join lateral private.current_parent_family_member_seasons(account.id)
          family on true
        join private.parent_portal_grants grant_row
          on grant_row.id = family.grant_id
          and grant_row.status = 'active'
          and grant_row.revoked_at is null
        join app.member_seasons member_season
          on member_season.id = family.member_season_id
        join app.members member on member.id = member_season.member_id
        where binding.recipient_identity_id = row_data.id
      ) child_data
    ), '[]'::jsonb)
  ) order by row_data.last_send_at desc nulls last, row_data.id), '[]'::jsonb)
  into recipients
  from (
    select *
    from rows
    order by last_send_at desc nulls last, id
    limit 20000
  ) row_data;
  return jsonb_build_object(
    'feedbackCapability', case
      when current_setting('app.settings.sendgrid_webhook_enabled', true) = 'true'
        then 'sendgrid_webhook'
      else 'smtp_sync_only'
    end,
    'recipients', coalesce(recipients, '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_email_control_center_v1()
from public, anon;
grant execute on function app.get_email_control_center_v1()
to authenticated;

-- A suppressed address still receives explicit security mail attempts so the
-- public endpoint remains enumeration-safe. Only bulk/reminder jobs are
-- terminally suppressed before a provider attempt.
create or replace function private.apply_recipient_suppression_to_email_job()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  if (
    new.kind = 'bulk'
    or new.template_key like '%_reminder'
  ) and exists(
    select 1
    from private.email_recipient_suppressions suppression
    join private.email_recipient_identities identity_row
      on identity_row.id = suppression.recipient_identity_id
    where identity_row.email_normalized = lower(btrim(new.recipient_email))
      and suppression.lifted_at is null
  ) then
    new.status := 'superseded';
    new.last_error := 'recipient_suppressed';
    new.available_at := statement_timestamp();
  end if;
  return new;
end;
$$;

create trigger email_jobs_apply_recipient_suppression
before insert on private.email_jobs
for each row execute function private.apply_recipient_suppression_to_email_job();

revoke all on function private.apply_recipient_suppression_to_email_job()
from public, anon, authenticated, service_role;

-- Recipient events stay visible but no longer turn global health red by
-- themselves. Infrastructure, integrity, queue and systemic provider failures
-- remain fail-closed through the existing v13 checks.
create or replace function app.get_operational_health_v14(
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
  snapshot jsonb := app.get_operational_health_v13(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
  email_recovery_boundary timestamptz := coalesce(
    (
      select reconciliation.reconciled_at
      from private.migration_reconciliations reconciliation
      where reconciliation.migration_key =
        '20260818133600_acknowledge_recovered_email_scheduler_health'
        and reconciliation.status = 'passed'
    ),
    '-infinity'::timestamptz
  );
  rejection_recovery_boundary timestamptz := coalesce(
    (
      select reconciliation.reconciled_at
      from private.migration_reconciliations reconciliation
      where reconciliation.migration_key =
        '20260818123100_acknowledge_pre_fix_parent_otp_rejections'
        and reconciliation.status = 'passed'
    ),
    '-infinity'::timestamptz
  );
  systemic_failed integer;
  systemic_otp_failed integer;
  systemic_email_provider_failures integer;
  systemic_otp_provider_failures integer;
begin
  select count(*)::integer into systemic_failed
  from private.email_jobs job
  where job.status = 'failed'
    and job.updated_at > email_recovery_boundary
    and not exists(
      select 1
      from private.email_delivery_attempts attempt
      join private.email_provider_sync_evidence evidence
        on evidence.delivery_attempt_id = attempt.id
      where attempt.id = job.current_delivery_attempt_id
        and evidence.recipient_failure
    );
  select count(*)::integer into systemic_otp_failed
  from private.parent_otp_delivery_outcomes failure
  where failure.outcome in ('provider_rejected', 'render_failed')
    and failure.created_at >= statement_timestamp() - interval '24 hours'
    and (
      failure.outcome = 'render_failed'
      or (
        failure.created_at > rejection_recovery_boundary
        and not exists(
          select 1
          from private.parent_otp_delivery_outcomes recovery
          where recovery.outcome = 'accepted'
            and recovery.created_at > failure.created_at
        )
      )
    )
    and not exists(
      select 1
      from private.email_provider_sync_evidence evidence
      where evidence.parent_otp_delivery_attempt_id
        = failure.delivery_attempt_id
        and evidence.recipient_failure
    );
  select count(*)::integer into systemic_email_provider_failures
  from app.email_events event
  join private.email_jobs job on job.id = event.email_job_id
  where event.event_type in ('bounced', 'dropped', 'failed')
    and event.occurred_at >= statement_timestamp() - interval '24 hours'
    and event.recorded_at > email_recovery_boundary
    and not (
      event.event_type = 'bounced'
      and exists(
        select 1
        from private.email_recipient_identities identity_row
        join private.email_recipient_suppressions suppression
          on suppression.recipient_identity_id = identity_row.id
          and suppression.lifted_at is null
        where identity_row.email_normalized = lower(btrim(job.recipient_email))
      )
    );
  select count(*)::integer into systemic_otp_provider_failures
  from (
    select distinct on (event.delivery_attempt_id)
      event.delivery_attempt_id,
      event.event_type,
      event.occurred_at
    from private.parent_otp_provider_events event
    order by event.delivery_attempt_id, event.occurred_at desc, event.id desc
  ) latest
  join private.parent_otp_delivery_attempts attempt
    on attempt.id = latest.delivery_attempt_id
  where latest.event_type in ('bounced', 'dropped', 'failed')
    and latest.occurred_at >= statement_timestamp() - interval '24 hours'
    and not (
      latest.event_type = 'bounced'
      and exists(
        select 1
        from private.email_recipient_suppressions suppression
        where suppression.recipient_identity_id = attempt.recipient_identity_id
          and suppression.lifted_at is null
      )
    );
  snapshot := jsonb_set(snapshot, '{emailJobs,failed}',
    to_jsonb(systemic_failed), false);
  snapshot := jsonb_set(snapshot, '{parentOtpDelivery,sendFailuresRecent}',
    to_jsonb(systemic_otp_failed), false);
  snapshot := jsonb_set(snapshot,
    '{parentOtpDelivery,providerFailuresRecent}',
    to_jsonb(systemic_otp_provider_failures), false);
  snapshot := jsonb_set(snapshot, '{recentDeliveryFailures}',
    to_jsonb(systemic_email_provider_failures), false);
  return snapshot;
end;
$$;

revoke all on function app.get_operational_health_v14(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v14(
  text, integer, text, integer
) to service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260821162000_email_recipient_health',
  'passed',
  jsonb_build_object(
    'recipientIdentities', (
      select count(*) from private.email_recipient_identities
    ),
    'activeSuppressions', (
      select count(*) from private.email_recipient_suppressions
      where lifted_at is null
    ),
    'unboundParentOtpAttempts', (
      select count(*) from private.parent_otp_delivery_attempts
      where recipient_identity_id is null
    )
  )
)
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = statement_timestamp();

select pg_notify('pgrst', 'reload schema');
