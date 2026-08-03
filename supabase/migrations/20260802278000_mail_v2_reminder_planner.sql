-- Reminder rules schedule only already-proven mail-v2 campaign segments.
-- Rules are inactive by default and every dispatch remains a normal,
-- revalidated domain event grouped per parent account.

create table app.mail_reminder_rules (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references app.seasons(id) on delete restrict,
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  internal_name text not null check (
    length(btrim(internal_name)) between 3 and 120
    and internal_name !~ '[[:cntrl:]]'
  ),
  first_delay_hours integer not null check (
    first_delay_hours between 1 and 2160
  ),
  frequency_hours integer not null check (
    frequency_hours between 1 and 2160
  ),
  maximum_dispatches integer not null check (
    maximum_dispatches between 1 and 20
  ),
  cooldown_hours integer not null check (
    cooldown_hours between 1 and 720
  ),
  end_at timestamptz,
  quiet_start time not null,
  quiet_end time not null,
  timezone text not null default 'Europe/Amsterdam' check (
    timezone = 'Europe/Amsterdam'
  ),
  active boolean not null default false,
  revision integer not null default 1 check (revision > 0),
  created_by uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  updated_by uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint mail_reminder_rules_template_check check (
    template_key in (
      'portal_access_reminder',
      'size_fill_reminder',
      'size_review_reminder',
      'payment_reminder',
      'pickup_reminder'
    )
  ),
  constraint mail_reminder_rules_quiet_window_check check (
    quiet_start <> quiet_end
  ),
  unique (season_id, template_key, internal_name)
);

create table private.mail_reminder_rule_revisions (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null
    references app.mail_reminder_rules(id) on delete restrict,
  revision integer not null check (revision > 0),
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  reason_code text not null check (
    reason_code in ('created', 'updated', 'activated', 'deactivated')
  ),
  config_snapshot jsonb not null check (
    jsonb_typeof(config_snapshot) = 'object'
    and octet_length(config_snapshot::text) between 16 and 4096
  ),
  created_at timestamptz not null default statement_timestamp(),
  unique (rule_id, revision)
);

create table private.mail_reminder_runs (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null
    references app.mail_reminder_rules(id) on delete restrict,
  rule_revision integer not null check (rule_revision > 0),
  status text not null check (
    status in ('succeeded', 'quiet_hours', 'inactive', 'failed')
  ),
  candidate_count integer not null default 0 check (candidate_count >= 0),
  dispatched_count integer not null default 0 check (dispatched_count >= 0),
  skipped_count integer not null default 0 check (skipped_count >= 0),
  error_code text check (
    error_code is null
    or error_code ~ '^[a-z0-9][a-z0-9._-]{1,99}$'
  ),
  started_at timestamptz not null,
  completed_at timestamptz not null,
  constraint mail_reminder_runs_error_state_check check (
    (
      status = 'failed'
      and error_code is not null
    )
    or (
      status <> 'failed'
      and error_code is null
    )
  )
);

create index mail_reminder_rules_active_idx
  on app.mail_reminder_rules(season_id, template_key, id)
  where active;
create index mail_reminder_rule_revisions_rule_idx
  on private.mail_reminder_rule_revisions(rule_id, revision desc);
create index mail_reminder_runs_rule_idx
  on private.mail_reminder_runs(rule_id, started_at desc);
create index mail_reminder_runs_failures_idx
  on private.mail_reminder_runs(completed_at desc, rule_id)
  where status = 'failed';

alter table app.mail_reminder_rules enable row level security;
alter table private.mail_reminder_rule_revisions enable row level security;
alter table private.mail_reminder_runs enable row level security;

revoke all on app.mail_reminder_rules
from public, anon, authenticated, service_role;
revoke all on private.mail_reminder_rule_revisions
from public, anon, authenticated, service_role;
revoke all on private.mail_reminder_runs
from public, anon, authenticated, service_role;

create or replace function private.reject_mail_reminder_fact_mutation()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  raise exception 'MAIL_REMINDER_FACT_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger mail_reminder_rule_revisions_immutable
before update or delete on private.mail_reminder_rule_revisions
for each row execute function private.reject_mail_reminder_fact_mutation();
create trigger mail_reminder_runs_immutable
before update or delete on private.mail_reminder_runs
for each row execute function private.reject_mail_reminder_fact_mutation();

revoke all on function private.reject_mail_reminder_fact_mutation()
from public, anon, authenticated, service_role;

create or replace function private.guard_mail_reminder_rule()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MAIL_REMINDER_RULE_DELETE_FORBIDDEN'
      using errcode = '23514';
  end if;
  if current_setting('app.mail_reminder_rule_internal', true) <> 'on' then
    raise exception 'MAIL_REMINDER_RULE_INTERNAL_REQUIRED'
      using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and (
    new.id is distinct from old.id
    or new.season_id is distinct from old.season_id
    or new.template_key is distinct from old.template_key
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or new.revision <> old.revision + 1
    or new.updated_at <= old.updated_at
  ) then
    raise exception 'MAIL_REMINDER_RULE_REVISION_INVALID'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger mail_reminder_rules_guard
before update or delete on app.mail_reminder_rules
for each row execute function private.guard_mail_reminder_rule();

revoke all on function private.guard_mail_reminder_rule()
from public, anon, authenticated, service_role;

create or replace function private.mail_reminder_rule_snapshot(
  p_rule app.mail_reminder_rules
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'seasonId', p_rule.season_id,
    'templateKey', p_rule.template_key,
    'internalName', p_rule.internal_name,
    'firstDelayHours', p_rule.first_delay_hours,
    'frequencyHours', p_rule.frequency_hours,
    'maximumDispatches', p_rule.maximum_dispatches,
    'cooldownHours', p_rule.cooldown_hours,
    'endAt', p_rule.end_at,
    'quietStart', to_char(p_rule.quiet_start, 'HH24:MI'),
    'quietEnd', to_char(p_rule.quiet_end, 'HH24:MI'),
    'timezone', p_rule.timezone,
    'active', p_rule.active
  );
$$;

revoke all on function private.mail_reminder_rule_snapshot(
  app.mail_reminder_rules
) from public, anon, authenticated, service_role;

create or replace function private.mail_reminder_process_key(
  p_template_key text
)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case p_template_key
    when 'portal_access_reminder' then 'portal_access'
    when 'size_fill_reminder' then 'size_confirmation'
    when 'size_review_reminder' then 'size_confirmation'
    when 'payment_reminder' then 'payment'
    when 'pickup_reminder' then 'pickup_reminder'
  end;
$$;

create or replace function private.mail_reminder_initial_template_key(
  p_template_key text
)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case p_template_key
    when 'portal_access_reminder' then 'portal_access_invite'
    when 'size_fill_reminder' then 'size_fill_request'
    when 'size_review_reminder' then 'size_review_request'
    when 'payment_reminder' then 'payment_request'
    when 'pickup_reminder' then 'pickup_ready'
  end;
$$;

revoke all on function private.mail_reminder_process_key(text)
from public, anon, authenticated, service_role;
revoke all on function private.mail_reminder_initial_template_key(text)
from public, anon, authenticated, service_role;

create or replace function private.mail_reminder_in_quiet_hours(
  p_rule app.mail_reminder_rules,
  p_now timestamptz
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  local_time time := (p_now at time zone p_rule.timezone)::time;
begin
  if p_rule.quiet_start < p_rule.quiet_end then
    return local_time >= p_rule.quiet_start
      and local_time < p_rule.quiet_end;
  end if;
  return local_time >= p_rule.quiet_start
    or local_time < p_rule.quiet_end;
end;
$$;

revoke all on function private.mail_reminder_in_quiet_hours(
  app.mail_reminder_rules, timestamptz
) from public, anon, authenticated, service_role;

create or replace function private.mail_reminder_due_candidates(
  p_rule_id uuid,
  p_now timestamptz
)
returns table(
  parent_account_id uuid,
  member_season_id uuid,
  order_id uuid,
  target_id uuid,
  episode_id uuid,
  next_sequence integer,
  due_at timestamptz
)
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_rule app.mail_reminder_rules%rowtype;
  candidate record;
  target_ids uuid[];
  target_process_key text;
  target_initial_template_key text;
  target_scope_type text;
  target_scope_id uuid;
  current_episode private.mail_v2_notification_episodes%rowtype;
  initial_sent_at timestamptz;
  last_dispatch_at timestamptz;
  dispatch_count integer;
  calculated_due_at timestamptz;
begin
  select * into target_rule
  from app.mail_reminder_rules rule
  where rule.id = p_rule_id;
  if not found or p_now is null then
    return;
  end if;
  target_process_key := private.mail_reminder_process_key(
    target_rule.template_key
  );
  target_initial_template_key := private.mail_reminder_initial_template_key(
    target_rule.template_key
  );
  if target_process_key is null
    or target_initial_template_key is null
  then
    return;
  end if;

  if target_rule.template_key = 'portal_access_reminder' then
    select coalesce(
      array_agg(member_season.id order by member_season.id),
      array[]::uuid[]
    ) into target_ids
    from app.member_seasons member_season
    where member_season.season_id = target_rule.season_id;
  else
    select coalesce(
      array_agg(orders.id order by orders.id),
      array[]::uuid[]
    ) into target_ids
    from app.member_orders orders
    where orders.season_id = target_rule.season_id;
  end if;

  for candidate in
    select *
    from private.mail_v2_campaign_candidates(
      target_rule.template_key,
      target_rule.season_id,
      target_ids
    )
    where outcome = 'eligible'
    order by parent_account_id, target_id, order_line_id
  loop
    target_scope_type := case
      when target_rule.template_key = 'portal_access_reminder'
        then 'member_season'
      else 'order'
    end;
    target_scope_id := case
      when target_rule.template_key = 'portal_access_reminder'
        then candidate.member_season_id
      else candidate.order_id
    end;
    current_episode := null;
    select * into current_episode
    from private.mail_v2_notification_episodes episode
    where episode.process_key = target_process_key
      and episode.parent_account_id = candidate.parent_account_id
      and episode.season_id = target_rule.season_id
      and episode.scope_type = target_scope_type
      and episode.scope_id = target_scope_id
      and episode.status = 'open';
    if current_episode.id is not null
      and current_episode.blocked_reason is not null
    then
      continue;
    end if;

    initial_sent_at := null;
    if target_rule.template_key = 'pickup_reminder' then
      select max(job.sent_at) into initial_sent_at
      from private.mail_v2_domain_events event
      join private.mail_v2_projections projection
        on projection.event_id = event.id
      join private.mail_v2_projection_batches batch
        on batch.id = projection.projection_batch_id
      join private.email_jobs job
        on job.id = batch.email_job_id
      where event.template_key = target_initial_template_key
        and event.parent_account_id = candidate.parent_account_id
        and event.order_id = candidate.order_id
        and job.status = 'sent'
        and coalesce(job.delivery_status, 'accepted')
          not in ('bounced', 'dropped', 'failed');
    elsif current_episode.id is not null then
      select max(job.sent_at) into initial_sent_at
      from private.mail_v2_episode_dispatches dispatch
      join private.mail_v2_domain_events event
        on event.id = dispatch.event_id
      join private.mail_v2_projections projection
        on projection.event_id = event.id
      join private.mail_v2_projection_batches batch
        on batch.id = projection.projection_batch_id
      join private.email_jobs job
        on job.id = batch.email_job_id
      where dispatch.episode_id = current_episode.id
        and dispatch.template_key = target_initial_template_key
        and job.status = 'sent'
        and coalesce(job.delivery_status, 'accepted')
          not in ('bounced', 'dropped', 'failed');
    end if;
    if initial_sent_at is null then
      continue;
    end if;

    dispatch_count := 0;
    last_dispatch_at := null;
    if current_episode.id is not null then
      select
        count(*)::integer,
        max(event.created_at)
      into dispatch_count, last_dispatch_at
      from private.mail_v2_episode_dispatches dispatch
      join private.mail_v2_domain_events event
        on event.id = dispatch.event_id
      where dispatch.episode_id = current_episode.id
        and dispatch.template_key = target_rule.template_key;
    end if;
    if dispatch_count >= target_rule.maximum_dispatches then
      continue;
    end if;
    calculated_due_at := case
      when dispatch_count = 0
        then initial_sent_at
          + make_interval(hours => target_rule.first_delay_hours)
      else greatest(
        last_dispatch_at
          + make_interval(hours => target_rule.frequency_hours),
        last_dispatch_at
          + make_interval(hours => target_rule.cooldown_hours)
      )
    end;
    if target_rule.end_at is not null
      and calculated_due_at > target_rule.end_at
    then
      continue;
    end if;

    parent_account_id := candidate.parent_account_id;
    member_season_id := candidate.member_season_id;
    order_id := candidate.order_id;
    target_id := target_scope_id;
    episode_id := current_episode.id;
    next_sequence := dispatch_count + 1;
    due_at := calculated_due_at;
    return next;
  end loop;
end;
$$;

revoke all on function private.mail_reminder_due_candidates(
  uuid, timestamptz
) from public, anon, authenticated, service_role;

create or replace function private.mail_reminder_rule_json(
  p_rule_id uuid,
  p_now timestamptz
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'id', rule.id,
    'seasonId', rule.season_id,
    'templateKey', rule.template_key,
    'internalName', rule.internal_name,
    'firstDelayHours', rule.first_delay_hours,
    'frequencyHours', rule.frequency_hours,
    'maximumDispatches', rule.maximum_dispatches,
    'cooldownHours', rule.cooldown_hours,
    'endAt', rule.end_at,
    'quietStart', to_char(rule.quiet_start, 'HH24:MI'),
    'quietEnd', to_char(rule.quiet_end, 'HH24:MI'),
    'timezone', rule.timezone,
    'active', rule.active,
    'revision', rule.revision,
    'dueNow', (
      select count(*)
      from private.mail_reminder_due_candidates(rule.id, p_now) candidate
      where candidate.due_at <= p_now
    ),
    'nextDueAt', (
      select min(candidate.due_at)
      from private.mail_reminder_due_candidates(rule.id, p_now) candidate
    ),
    'lastRunAt', (
      select max(run.completed_at)
      from private.mail_reminder_runs run
      where run.rule_id = rule.id
    ),
    'lastRunStatus', (
      select run.status
      from private.mail_reminder_runs run
      where run.rule_id = rule.id
      order by run.completed_at desc, run.id desc
      limit 1
    ),
    'createdAt', rule.created_at,
    'updatedAt', rule.updated_at
  )
  from app.mail_reminder_rules rule
  where rule.id = p_rule_id;
$$;

revoke all on function private.mail_reminder_rule_json(uuid, timestamptz)
from public, anon, authenticated, service_role;

create or replace function app.get_mail_reminder_workspace_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  now_utc timestamptz := statement_timestamp();
begin
  return jsonb_build_object(
    'timezone',
    'Europe/Amsterdam',
    'newRulesDefaultActive',
    false,
    'rules',
    coalesce((
      select jsonb_agg(
        private.mail_reminder_rule_json(rule.id, now_utc)
        order by season.name desc, rule.internal_name, rule.id
      )
      from app.mail_reminder_rules rule
      join app.seasons season on season.id = rule.season_id
    ), '[]'::jsonb),
    'seasons',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'status', season.status
      ) order by season.name desc, season.id)
      from app.seasons season
      where season.status in ('open', 'archived')
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_mail_reminder_workspace_v1()
from public, anon;
grant execute on function app.get_mail_reminder_workspace_v1()
to authenticated;

create or replace function app.save_mail_reminder_rule_v1(
  p_rule_id uuid,
  p_season_id uuid,
  p_template_key text,
  p_expected_revision integer,
  p_config jsonb,
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
  target app.mail_reminder_rules%rowtype;
  saved app.mail_reminder_rules%rowtype;
  now_utc timestamptz := statement_timestamp();
  new_internal_name text;
  new_first_delay_hours integer;
  new_frequency_hours integer;
  new_maximum_dispatches integer;
  new_cooldown_hours integer;
  new_end_at timestamptz;
  new_quiet_start time;
  new_quiet_end time;
begin
  if p_season_id is null
    or p_template_key not in (
      'portal_access_reminder',
      'size_fill_reminder',
      'size_review_reminder',
      'payment_reminder',
      'pickup_reminder'
    )
    or jsonb_typeof(p_config) <> 'object'
    or not p_config ?& array[
      'internalName',
      'firstDelayHours',
      'frequencyHours',
      'maximumDispatches',
      'cooldownHours',
      'endAt',
      'quietStart',
      'quietEnd'
    ]
    or exists(
      select 1
      from jsonb_object_keys(p_config) key
      where key <> all(array[
        'internalName',
        'firstDelayHours',
        'frequencyHours',
        'maximumDispatches',
        'cooldownHours',
        'endAt',
        'quietStart',
        'quietEnd'
      ])
    )
  then
    raise exception 'MAIL_REMINDER_RULE_INPUT_INVALID'
      using errcode = '22023';
  end if;
  begin
    new_internal_name := btrim(p_config->>'internalName');
    new_first_delay_hours := (p_config->>'firstDelayHours')::integer;
    new_frequency_hours := (p_config->>'frequencyHours')::integer;
    new_maximum_dispatches := (p_config->>'maximumDispatches')::integer;
    new_cooldown_hours := (p_config->>'cooldownHours')::integer;
    new_end_at := nullif(p_config->>'endAt', '')::timestamptz;
    new_quiet_start := (p_config->>'quietStart')::time;
    new_quiet_end := (p_config->>'quietEnd')::time;
  exception
    when others then
      raise exception 'MAIL_REMINDER_RULE_INPUT_INVALID'
        using errcode = '22023';
  end;
  if length(new_internal_name) not between 3 and 120
    or new_internal_name ~ '[[:cntrl:]]'
    or new_first_delay_hours not between 1 and 2160
    or new_frequency_hours not between 1 and 2160
    or new_maximum_dispatches not between 1 and 20
    or new_cooldown_hours not between 1 and 720
    or new_quiet_start = new_quiet_end
    or (new_end_at is not null and new_end_at <= now_utc)
    or not exists(
      select 1
      from app.seasons season
      where season.id = p_season_id
        and season.status in ('open', 'archived')
    )
  then
    raise exception 'MAIL_REMINDER_RULE_INPUT_INVALID'
      using errcode = '22023';
  end if;
  perform 1
  from app.mail_template_revisions revision
  where revision.template_key = p_template_key
    and revision.status = 'published';
  if not found then
    raise exception 'MAIL_REMINDER_TEMPLATE_NOT_PUBLISHED'
      using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'mail-reminder-rule:'
        || coalesce(p_rule_id::text, p_season_id::text || ':' || p_template_key),
      0
    )
  );
  perform set_config('app.mail_reminder_rule_internal', 'on', true);
  if p_rule_id is null then
    insert into app.mail_reminder_rules(
      season_id,
      template_key,
      internal_name,
      first_delay_hours,
      frequency_hours,
      maximum_dispatches,
      cooldown_hours,
      end_at,
      quiet_start,
      quiet_end,
      active,
      created_by,
      updated_by
    ) values (
      p_season_id,
      p_template_key,
      new_internal_name,
      new_first_delay_hours,
      new_frequency_hours,
      new_maximum_dispatches,
      new_cooldown_hours,
      new_end_at,
      new_quiet_start,
      new_quiet_end,
      false,
      actor,
      actor
    )
    returning * into saved;
    insert into private.mail_reminder_rule_revisions(
      rule_id,
      revision,
      actor_user_id,
      reason_code,
      config_snapshot
    ) values (
      saved.id,
      saved.revision,
      actor,
      'created',
      private.mail_reminder_rule_snapshot(saved)
    );
  else
    select * into target
    from app.mail_reminder_rules rule
    where rule.id = p_rule_id
    for update;
    if not found then
      raise exception 'MAIL_REMINDER_RULE_NOT_FOUND' using errcode = 'P0002';
    end if;
    if target.season_id <> p_season_id
      or target.template_key <> p_template_key
      or p_expected_revision is null
      or target.revision <> p_expected_revision
    then
      raise exception 'MAIL_REMINDER_RULE_CONFLICT' using errcode = '40001';
    end if;
    update app.mail_reminder_rules
    set internal_name = new_internal_name,
        first_delay_hours = new_first_delay_hours,
        frequency_hours = new_frequency_hours,
        maximum_dispatches = new_maximum_dispatches,
        cooldown_hours = new_cooldown_hours,
        end_at = new_end_at,
        quiet_start = new_quiet_start,
        quiet_end = new_quiet_end,
        active = false,
        revision = target.revision + 1,
        updated_by = actor,
        updated_at = now_utc
    where id = target.id
    returning * into saved;
    insert into private.mail_reminder_rule_revisions(
      rule_id,
      revision,
      actor_user_id,
      reason_code,
      config_snapshot
    ) values (
      saved.id,
      saved.revision,
      actor,
      'updated',
      private.mail_reminder_rule_snapshot(saved)
    );
  end if;
  perform set_config('app.mail_reminder_rule_internal', 'off', true);

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'mail_reminder.rule_saved',
    'mail_reminder_rule',
    saved.id,
    jsonb_build_object(
      'seasonId', saved.season_id,
      'templateKey', saved.template_key,
      'revision', saved.revision,
      'active', false
    ),
    p_correlation_id
  );
  return private.mail_reminder_rule_json(saved.id, now_utc);
exception
  when unique_violation then
    perform set_config('app.mail_reminder_rule_internal', 'off', true);
    raise exception 'MAIL_REMINDER_RULE_CONFLICT' using errcode = '23505';
  when others then
    perform set_config('app.mail_reminder_rule_internal', 'off', true);
    raise;
end;
$$;

revoke all on function app.save_mail_reminder_rule_v1(
  uuid, uuid, text, integer, jsonb, uuid
) from public, anon;
grant execute on function app.save_mail_reminder_rule_v1(
  uuid, uuid, text, integer, jsonb, uuid
) to authenticated;

create or replace function app.set_mail_reminder_rule_active_v1(
  p_rule_id uuid,
  p_expected_revision integer,
  p_active boolean,
  p_reason text,
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
  target app.mail_reminder_rules%rowtype;
  saved app.mail_reminder_rules%rowtype;
  now_utc timestamptz := statement_timestamp();
begin
  if p_rule_id is null
    or p_expected_revision is null
    or p_active is null
    or length(btrim(p_reason)) not between 3 and 240
    or p_reason ~ '[[:cntrl:]]'
  then
    raise exception 'MAIL_REMINDER_RULE_STATE_INVALID'
      using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-reminder-rule:' || p_rule_id::text, 0)
  );
  select * into target
  from app.mail_reminder_rules rule
  where rule.id = p_rule_id
  for update;
  if not found then
    raise exception 'MAIL_REMINDER_RULE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.revision <> p_expected_revision then
    raise exception 'MAIL_REMINDER_RULE_CONFLICT' using errcode = '40001';
  end if;
  if p_active and (
    target.end_at is not null
    and target.end_at <= now_utc
  ) then
    raise exception 'MAIL_REMINDER_RULE_ENDED' using errcode = '23514';
  end if;
  if p_active and (
    not exists(
      select 1
      from app.seasons season
      where season.id = target.season_id
        and season.status = 'open'
    )
    or not exists(
      select 1
      from app.mail_template_revisions revision
      where revision.template_key = target.template_key
        and revision.status = 'published'
    )
    or not exists(
      select 1
      from private.mail_v2_process_capabilities capability
      where capability.template_key = target.template_key
        and capability.enabled
    )
  ) then
    raise exception 'MAIL_REMINDER_RULE_NOT_READY' using errcode = '23514';
  end if;
  perform set_config('app.mail_reminder_rule_internal', 'on', true);
  update app.mail_reminder_rules
  set active = p_active,
      revision = target.revision + 1,
      updated_by = actor,
      updated_at = now_utc
  where id = target.id
  returning * into saved;
  insert into private.mail_reminder_rule_revisions(
    rule_id,
    revision,
    actor_user_id,
    reason_code,
    config_snapshot
  ) values (
    saved.id,
    saved.revision,
    actor,
    case when p_active then 'activated' else 'deactivated' end,
    private.mail_reminder_rule_snapshot(saved)
  );
  perform set_config('app.mail_reminder_rule_internal', 'off', true);

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    case when p_active
      then 'mail_reminder.rule_activated'
      else 'mail_reminder.rule_deactivated'
    end,
    'mail_reminder_rule',
    saved.id,
    jsonb_build_object(
      'seasonId', saved.season_id,
      'templateKey', saved.template_key,
      'revision', saved.revision,
      'active', saved.active,
      'reasonDigest', encode(
        extensions.digest(convert_to(btrim(p_reason), 'UTF8'), 'sha256'),
        'hex'
      ),
      'reasonLength', length(btrim(p_reason))
    ),
    p_correlation_id
  );
  return private.mail_reminder_rule_json(saved.id, now_utc);
exception
  when others then
    perform set_config('app.mail_reminder_rule_internal', 'off', true);
    raise;
end;
$$;

revoke all on function app.set_mail_reminder_rule_active_v1(
  uuid, integer, boolean, text, uuid
) from public, anon;
grant execute on function app.set_mail_reminder_rule_active_v1(
  uuid, integer, boolean, text, uuid
) to authenticated;

create or replace function app.run_due_mail_reminders_v1(
  p_now timestamptz,
  p_limit integer default 500
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_rule app.mail_reminder_rules%rowtype;
  candidate record;
  run_id uuid;
  event_id uuid;
  total_candidates integer := 0;
  total_dispatched integer := 0;
  total_skipped integer := 0;
  total_failed integer := 0;
  rule_candidates integer;
  rule_dispatched integer;
  rule_skipped integer;
  current_count integer;
begin
  if p_now is null or p_limit not between 1 and 2000 then
    raise exception 'MAIL_REMINDER_RUN_INPUT_INVALID' using errcode = '22023';
  end if;
  if not private.mail_templates_v2_enabled() then
    return jsonb_build_object(
      'status', 'paused',
      'candidateCount', 0,
      'dispatchedCount', 0,
      'skippedCount', 0,
      'failedRuleCount', 0
    );
  end if;

  for target_rule in
    select rule.*
    from app.mail_reminder_rules rule
    where rule.active
      and (rule.end_at is null or rule.end_at >= p_now)
    order by rule.id
  loop
    run_id := gen_random_uuid();
    rule_candidates := 0;
    rule_dispatched := 0;
    rule_skipped := 0;
    perform pg_advisory_xact_lock(
      hashtextextended('mail-reminder-rule:' || target_rule.id::text, 0)
    );
    begin
    select * into target_rule
    from app.mail_reminder_rules rule
    where rule.id = target_rule.id
    for update;
    if not target_rule.active then
      insert into private.mail_reminder_runs(
        id, rule_id, rule_revision, status,
        started_at, completed_at
      ) values (
        run_id, target_rule.id, target_rule.revision, 'inactive',
        p_now, statement_timestamp()
      );
      continue;
    end if;
    if private.mail_reminder_in_quiet_hours(target_rule, p_now) then
      insert into private.mail_reminder_runs(
        id, rule_id, rule_revision, status,
        started_at, completed_at
      ) values (
        run_id, target_rule.id, target_rule.revision, 'quiet_hours',
        p_now, statement_timestamp()
      );
      continue;
    end if;

    for candidate in
      select *
      from private.mail_reminder_due_candidates(target_rule.id, p_now)
      where due_at <= p_now
      order by due_at, parent_account_id, target_id
    loop
      exit when total_dispatched >= p_limit;
      rule_candidates := rule_candidates + 1;
      total_candidates := total_candidates + 1;
      perform pg_advisory_xact_lock(
        hashtextextended(
          'mail-reminder-dispatch:'
            || target_rule.id::text
            || ':'
            || candidate.parent_account_id::text
            || ':'
            || candidate.target_id::text,
          0
        )
      );
      select count(*)::integer into current_count
      from private.mail_v2_notification_episodes episode
      join private.mail_v2_episode_dispatches dispatch
        on dispatch.episode_id = episode.id
      where episode.process_key =
          private.mail_reminder_process_key(target_rule.template_key)
        and episode.parent_account_id = candidate.parent_account_id
        and episode.season_id = target_rule.season_id
        and episode.scope_type = case
          when target_rule.template_key = 'portal_access_reminder'
            then 'member_season'
          else 'order'
        end
        and episode.scope_id = candidate.target_id
        and episode.status = 'open'
        and dispatch.template_key = target_rule.template_key;
      if current_count + 1 <> candidate.next_sequence then
        rule_skipped := rule_skipped + 1;
        total_skipped := total_skipped + 1;
        continue;
      end if;

      event_id := private.enqueue_mail_v2_member_event(
        target_rule.template_key,
        candidate.parent_account_id,
        candidate.member_season_id,
        'mail_reminder_rule',
        target_rule.id,
        run_id,
        concat_ws(
          ':',
          'mail-reminder-v1',
          target_rule.id,
          candidate.parent_account_id,
          candidate.target_id,
          candidate.next_sequence
        )
      );
      if private.mail_v2_event_state(event_id) <> 'eligible' then
        rule_skipped := rule_skipped + 1;
        total_skipped := total_skipped + 1;
        continue;
      end if;
      rule_dispatched := rule_dispatched + 1;
      total_dispatched := total_dispatched + 1;
    end loop;
    insert into private.mail_reminder_runs(
      id,
      rule_id,
      rule_revision,
      status,
      candidate_count,
      dispatched_count,
      skipped_count,
      started_at,
      completed_at
    ) values (
      run_id,
      target_rule.id,
      target_rule.revision,
      'succeeded',
      rule_candidates,
      rule_dispatched,
      rule_skipped,
      p_now,
      statement_timestamp()
    );
    exception
      when others then
        total_failed := total_failed + 1;
        insert into private.mail_reminder_runs(
          id,
          rule_id,
          rule_revision,
          status,
          candidate_count,
          dispatched_count,
          skipped_count,
          error_code,
          started_at,
          completed_at
        ) values (
          run_id,
          target_rule.id,
          target_rule.revision,
          'failed',
          rule_candidates,
          rule_dispatched,
          rule_skipped,
          'rule_execution_failed',
          p_now,
          statement_timestamp()
        );
    end;
    exit when total_dispatched >= p_limit;
  end loop;
  return jsonb_build_object(
    'status', 'completed',
    'candidateCount', total_candidates,
    'dispatchedCount', total_dispatched,
    'skippedCount', total_skipped,
    'failedRuleCount', total_failed
  );
exception
  when others then
    raise;
end;
$$;

revoke all on function app.run_due_mail_reminders_v1(
  timestamptz, integer
) from public, anon, authenticated;
grant execute on function app.run_due_mail_reminders_v1(
  timestamptz, integer
) to service_role;

create or replace function app.get_operational_health_v8(
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
  base jsonb := app.get_operational_health_v7(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
begin
  return base || jsonb_build_object(
    'reminderPlanner',
    jsonb_build_object(
      'activeRules',
      (
        select count(*)
        from app.mail_reminder_rules rule
        where rule.active
      ),
      'failedRunsRecent',
      (
        select count(*)
        from private.mail_reminder_runs run
        where run.status = 'failed'
          and run.completed_at >= statement_timestamp() - interval '24 hours'
      ),
      'activeRulesNeverRun',
      (
        select count(*)
        from app.mail_reminder_rules rule
        where rule.active
          and rule.updated_at
            < statement_timestamp() - interval '15 minutes'
          and not exists(
            select 1
            from private.mail_reminder_runs run
            where run.rule_id = rule.id
          )
      ),
      'lastCompletedAt',
      (
        select max(run.completed_at)
        from private.mail_reminder_runs run
      )
    )
  );
end;
$$;

revoke all on function app.get_operational_health_v8(
  text, integer, text, integer
)
from public, anon, authenticated;
grant execute on function app.get_operational_health_v8(
  text, integer, text, integer
)
to service_role;

insert into private.mail_v2_process_capabilities(
  template_key,
  producer_version
) values
  ('portal_access_reminder', 1),
  ('size_fill_reminder', 1),
  ('size_review_reminder', 1),
  ('payment_reminder', 1),
  ('pickup_reminder', 1)
on conflict (template_key) do update
set producer_version = excluded.producer_version,
    enabled = true,
    registered_at = statement_timestamp();

do $$
declare
  direct_rule_access bigint;
  producer_count integer;
begin
  select count(*) into direct_rule_access
  from information_schema.role_table_grants grant_row
  where grant_row.table_schema in ('app', 'private')
    and grant_row.table_name in (
      'mail_reminder_rules',
      'mail_reminder_rule_revisions',
      'mail_reminder_runs'
    )
    and grant_row.grantee in (
      'anon',
      'authenticated',
      'service_role'
    );
  select count(*)::integer into producer_count
  from private.mail_v2_process_capabilities capability
  where capability.enabled;
  if direct_rule_access <> 0 or producer_count <> 18 then
    raise exception 'MAIL_REMINDER_PLANNER_RECONCILIATION_FAILED'
      using errcode = '23514';
  end if;
  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260802278000_mail_v2_reminder_planner',
    'passed',
    jsonb_build_object(
      'rules', (select count(*) from app.mail_reminder_rules),
      'activeRules', (
        select count(*) from app.mail_reminder_rules where active
      ),
      'enabledProducers', producer_count
    )
  )
  on conflict (migration_key) do update
  set status = excluded.status,
      metrics = excluded.metrics,
      reconciled_at = statement_timestamp();
end;
$$;

comment on table app.mail_reminder_rules is
  'AAL2-managed Europe/Amsterdam reminder schedules; new and edited rules are inactive.';
comment on function app.run_due_mail_reminders_v1(timestamptz, integer) is
  'Produces revalidated family-consolidated reminder events without sending provider traffic.';

select pg_notify('pgrst', 'reload schema');
