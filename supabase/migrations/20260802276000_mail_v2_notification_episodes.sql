create table private.mail_v2_notification_episodes (
  id uuid primary key default gen_random_uuid(),
  process_key text not null check (
    process_key in (
      'portal_access',
      'size_confirmation',
      'payment',
      'payment_waiting_stock',
      'availability_payment',
      'shortage',
      'pickup',
      'pickup_reminder',
      'internal_email_failure'
    )
  ),
  parent_account_id uuid
    references private.parent_accounts(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  scope_type text not null check (
    scope_type in ('member_season', 'order', 'order_line', 'email_job')
  ),
  scope_id uuid not null,
  episode_number integer not null check (episode_number > 0),
  status text not null default 'open' check (status in ('open', 'closed')),
  blocked_reason text check (
    blocked_reason is null
    or blocked_reason in (
      'delivery_uncertain',
      'delivery_failed',
      'delivery_bounced',
      'delivery_dropped',
      'projection_retry_exhausted'
    )
  ),
  opening_event_id uuid not null
    references private.mail_v2_domain_events(id) on delete restrict,
  opened_at timestamptz not null default statement_timestamp(),
  closed_at timestamptz,
  close_reason text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint mail_v2_notification_episode_context_check check (
    (
      process_key = 'internal_email_failure'
      and parent_account_id is null
      and scope_type = 'email_job'
    )
    or (
      process_key <> 'internal_email_failure'
      and parent_account_id is not null
      and scope_type <> 'email_job'
    )
  ),
  constraint mail_v2_notification_episode_lifecycle_check check (
    (
      status = 'open'
      and closed_at is null
      and close_reason is null
    )
    or (
      status = 'closed'
      and closed_at is not null
      and length(btrim(close_reason)) between 3 and 120
      and blocked_reason is null
    )
  ),
  unique (
    process_key,
    season_id,
    scope_type,
    scope_id,
    episode_number
  )
);

create unique index mail_v2_notification_episodes_one_open_idx
  on private.mail_v2_notification_episodes(
    process_key,
    season_id,
    scope_type,
    scope_id,
    coalesce(
      parent_account_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    )
  )
  where status = 'open';
create index mail_v2_notification_episodes_parent_idx
  on private.mail_v2_notification_episodes(
    parent_account_id,
    season_id,
    status,
    process_key
  )
  where parent_account_id is not null;
create index mail_v2_notification_episodes_blocked_idx
  on private.mail_v2_notification_episodes(updated_at, id)
  where status = 'open' and blocked_reason is not null;

create table private.mail_v2_episode_dispatches (
  id uuid primary key default gen_random_uuid(),
  episode_id uuid not null
    references private.mail_v2_notification_episodes(id) on delete restrict,
  event_id uuid not null
    references private.mail_v2_domain_events(id) on delete restrict,
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  dispatch_kind text not null check (
    dispatch_kind in ('initial', 'reminder', 'status', 'recovery')
  ),
  sequence_number integer not null check (sequence_number > 0),
  created_at timestamptz not null default statement_timestamp(),
  unique (episode_id, event_id)
);

create unique index mail_v2_episode_dispatches_sequence_idx
  on private.mail_v2_episode_dispatches(
    episode_id,
    dispatch_kind,
    sequence_number
  );
create index mail_v2_episode_dispatches_event_idx
  on private.mail_v2_episode_dispatches(event_id, episode_id);

create table private.mail_v2_episode_transitions (
  id bigint generated always as identity primary key,
  episode_id uuid not null
    references private.mail_v2_notification_episodes(id) on delete restrict,
  from_status text check (from_status is null or from_status in ('open', 'closed')),
  to_status text not null check (to_status in ('open', 'closed')),
  from_blocked_reason text,
  to_blocked_reason text,
  reason_code text not null check (
    reason_code ~ '^[a-z][a-z0-9_.]{2,119}$'
  ),
  source_type text not null check (
    source_type in (
      'domain_event',
      'event_suppression',
      'email_job',
      'provider_event',
      'payment',
      'parent_login',
      'portal_grant',
      'inventory_allocation',
      'inventory_movement',
      'member_season',
      'order_line',
      'size_profile',
      'season',
      'backfill'
    )
  ),
  source_id uuid,
  actor_user_id uuid
    references app.staff_profiles(auth_user_id) on delete restrict,
  created_at timestamptz not null default statement_timestamp()
);
create index mail_v2_episode_transitions_episode_idx
  on private.mail_v2_episode_transitions(episode_id, id);

alter table private.mail_v2_notification_episodes enable row level security;
alter table private.mail_v2_episode_dispatches enable row level security;
alter table private.mail_v2_episode_transitions enable row level security;

revoke all on private.mail_v2_notification_episodes
from public, anon, authenticated, service_role;
revoke all on private.mail_v2_episode_dispatches
from public, anon, authenticated, service_role;
revoke all on private.mail_v2_episode_transitions
from public, anon, authenticated, service_role;

create or replace function private.guard_mail_v2_notification_episode()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MAIL_V2_EPISODE_IMMUTABLE' using errcode = '23514';
  end if;
  if current_setting('app.mail_v2_episode_internal', true) <> 'on' then
    raise exception 'MAIL_V2_EPISODE_INTERNAL_REQUIRED' using errcode = '23514';
  end if;
  if new.id is distinct from old.id
    or new.process_key is distinct from old.process_key
    or new.parent_account_id is distinct from old.parent_account_id
    or new.season_id is distinct from old.season_id
    or new.scope_type is distinct from old.scope_type
    or new.scope_id is distinct from old.scope_id
    or new.episode_number is distinct from old.episode_number
    or new.opening_event_id is distinct from old.opening_event_id
    or new.opened_at is distinct from old.opened_at
    or new.created_at is distinct from old.created_at
    or old.status = 'closed'
    or (
      new.status = 'open'
      and (
        new.closed_at is not null
        or new.close_reason is not null
      )
    )
    or (
      new.status = 'closed'
      and (
        new.closed_at is null
        or new.close_reason is null
        or new.blocked_reason is not null
      )
    )
  then
    raise exception 'MAIL_V2_EPISODE_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger mail_v2_notification_episodes_guard
before update or delete on private.mail_v2_notification_episodes
for each row execute function private.guard_mail_v2_notification_episode();

create or replace function private.reject_mail_v2_episode_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  raise exception 'MAIL_V2_EPISODE_LEDGER_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger mail_v2_episode_dispatches_immutable
before update or delete on private.mail_v2_episode_dispatches
for each row execute function private.reject_mail_v2_episode_ledger_mutation();
create trigger mail_v2_episode_transitions_immutable
before update or delete on private.mail_v2_episode_transitions
for each row execute function private.reject_mail_v2_episode_ledger_mutation();

revoke all on function private.guard_mail_v2_notification_episode()
from public, anon, authenticated, service_role;
revoke all on function private.reject_mail_v2_episode_ledger_mutation()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_episode_descriptors(
  p_event_id uuid
)
returns table(
  process_key text,
  scope_type text,
  scope_id uuid,
  dispatch_kind text
)
language sql
stable
security definer
set search_path = private, app, pg_temp
as $$
  select
    descriptor.process_key,
    descriptor.scope_type,
    descriptor.scope_id,
    descriptor.dispatch_kind
  from private.mail_v2_domain_events event
  cross join lateral (
    select
      case
        when event.template_key in (
          'portal_access_invite',
          'portal_access_reminder'
        ) then 'portal_access'
        when event.template_key in (
          'size_fill_request',
          'size_fill_reminder',
          'size_review_request',
          'size_review_reminder',
          'size_confirmed'
        ) then 'size_confirmation'
        when event.template_key in (
          'payment_request',
          'payment_reminder'
        ) then 'payment'
        when event.template_key =
          'payment_received_waiting_stock'
        then 'payment_waiting_stock'
        when event.template_key =
          'available_payment_required'
        then 'availability_payment'
        when event.template_key = 'out_of_stock'
        then 'shortage'
        when event.template_key = 'pickup_ready'
        then 'pickup'
        when event.template_key = 'pickup_reminder'
        then 'pickup_reminder'
        when event.template_key = 'internal_email_failure'
        then 'internal_email_failure'
      end process_key,
      case
        when event.template_key in (
          'portal_access_invite',
          'portal_access_reminder'
        ) then 'member_season'
        when event.template_key in (
          'out_of_stock',
          'pickup_ready'
        ) then 'order_line'
        when event.template_key = 'internal_email_failure'
        then 'email_job'
        else 'order'
      end scope_type,
      case
        when event.template_key in (
          'portal_access_invite',
          'portal_access_reminder'
        ) then event.member_season_id
        when event.template_key in (
          'out_of_stock',
          'pickup_ready'
        ) then event.order_line_id
        when event.template_key = 'internal_email_failure'
        then event.source_id
        else event.order_id
      end scope_id,
      case
        when event.template_key like '%_reminder' then 'reminder'
        when event.template_key in ('size_confirmed') then 'status'
        else 'initial'
      end dispatch_kind
    union all
    select
      'shortage',
      'order_line',
      event.order_line_id,
      'status'
    where event.template_key = 'back_in_stock'
    union all
    select
      'pickup',
      'order_line',
      event.order_line_id,
      'status'
    where event.template_key = 'back_in_stock'
  ) descriptor
  where event.id = p_event_id
    and descriptor.process_key is not null
    and descriptor.scope_id is not null;
$$;

revoke all on function private.mail_v2_episode_descriptors(uuid)
from public, anon, authenticated, service_role;

create or replace function private.transition_mail_v2_notification_episode(
  p_episode_id uuid,
  p_target_status text,
  p_reason_code text,
  p_blocked_reason text,
  p_source_type text,
  p_source_id uuid default null,
  p_actor_user_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target private.mail_v2_notification_episodes%rowtype;
  old_blocked_reason text;
begin
  if p_target_status not in ('open', 'closed')
    or p_reason_code !~ '^[a-z][a-z0-9_.]{2,119}$'
    or p_source_type not in (
      'domain_event',
      'event_suppression',
      'email_job',
      'provider_event',
      'payment',
      'parent_login',
      'portal_grant',
      'inventory_allocation',
      'inventory_movement',
      'member_season',
      'order_line',
      'size_profile',
      'season',
      'backfill'
    )
    or (
      p_target_status = 'closed'
      and p_blocked_reason is not null
    )
  then
    raise exception 'MAIL_V2_EPISODE_TRANSITION_INVALID'
      using errcode = '22023';
  end if;
  select * into target
  from private.mail_v2_notification_episodes episode
  where episode.id = p_episode_id
  for update;
  if not found then
    return false;
  end if;
  if target.status = 'closed' then
    return false;
  end if;
  old_blocked_reason := target.blocked_reason;
  if p_target_status = 'open'
    and old_blocked_reason is not distinct from p_blocked_reason
  then
    return false;
  end if;

  perform set_config('app.mail_v2_episode_internal', 'on', true);
  update private.mail_v2_notification_episodes
  set status = p_target_status,
      blocked_reason = p_blocked_reason,
      closed_at = case
        when p_target_status = 'closed' then statement_timestamp()
        else null
      end,
      close_reason = case
        when p_target_status = 'closed' then p_reason_code
        else null
      end,
      updated_at = statement_timestamp()
  where id = target.id;
  perform set_config('app.mail_v2_episode_internal', 'off', true);

  insert into private.mail_v2_episode_transitions(
    episode_id,
    from_status,
    to_status,
    from_blocked_reason,
    to_blocked_reason,
    reason_code,
    source_type,
    source_id,
    actor_user_id
  ) values (
    target.id,
    target.status,
    p_target_status,
    old_blocked_reason,
    p_blocked_reason,
    p_reason_code,
    p_source_type,
    p_source_id,
    p_actor_user_id
  );
  return true;
exception
  when others then
    perform set_config('app.mail_v2_episode_internal', 'off', true);
    raise;
end;
$$;

revoke all on function private.transition_mail_v2_notification_episode(
  uuid, text, text, text, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.bind_mail_v2_event_to_episodes(
  p_event_id uuid,
  p_backfill boolean default false
)
returns integer
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  descriptor record;
  episode private.mail_v2_notification_episodes%rowtype;
  next_episode_number integer;
  next_sequence integer;
  bound_count integer := 0;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found then
    return 0;
  end if;

  for descriptor in
    select *
    from private.mail_v2_episode_descriptors(target.id)
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      concat_ws(
        ':',
        'mail-v2-episode',
        descriptor.process_key,
        target.season_id::text,
        descriptor.scope_type,
        descriptor.scope_id::text,
        coalesce(target.parent_account_id::text, 'internal')
      ),
      0
    ));
    episode := null;
    select * into episode
    from private.mail_v2_notification_episodes current_episode
    where current_episode.process_key = descriptor.process_key
      and current_episode.season_id = target.season_id
      and current_episode.scope_type = descriptor.scope_type
      and current_episode.scope_id = descriptor.scope_id
      and current_episode.parent_account_id is not distinct from
        target.parent_account_id
      and current_episode.status = 'open'
    for update;

    if episode.id is null then
      if descriptor.dispatch_kind = 'status'
        and target.template_key = 'back_in_stock'
        and descriptor.process_key = 'shortage'
      then
        continue;
      end if;
      select coalesce(max(prior.episode_number), 0) + 1
      into next_episode_number
      from private.mail_v2_notification_episodes prior
      where prior.process_key = descriptor.process_key
        and prior.season_id = target.season_id
        and prior.scope_type = descriptor.scope_type
        and prior.scope_id = descriptor.scope_id
        and prior.parent_account_id is not distinct from
          target.parent_account_id;
      insert into private.mail_v2_notification_episodes(
        process_key,
        parent_account_id,
        season_id,
        scope_type,
        scope_id,
        episode_number,
        opening_event_id,
        opened_at,
        created_at,
        updated_at
      ) values (
        descriptor.process_key,
        target.parent_account_id,
        target.season_id,
        descriptor.scope_type,
        descriptor.scope_id,
        next_episode_number,
        target.id,
        target.created_at,
        target.created_at,
        target.created_at
      )
      returning * into episode;
      insert into private.mail_v2_episode_transitions(
        episode_id,
        from_status,
        to_status,
        reason_code,
        source_type,
        source_id,
        created_at
      ) values (
        episode.id,
        null,
        'open',
        'episode.opened',
        case when p_backfill then 'backfill' else 'domain_event' end,
        target.id,
        target.created_at
      );
    end if;

    if episode.blocked_reason is not null
      and descriptor.dispatch_kind in ('initial', 'reminder')
      and not exists(
        select 1
        from private.mail_v2_episode_dispatches dispatch
        where dispatch.episode_id = episode.id
          and dispatch.event_id = target.id
      )
    then
      raise exception 'MAIL_V2_NOTIFICATION_EPISODE_BLOCKED'
        using errcode = '55000';
    end if;
    if exists(
      select 1
      from private.mail_v2_episode_dispatches dispatch
      where dispatch.episode_id = episode.id
        and dispatch.event_id = target.id
    ) then
      continue;
    end if;
    select coalesce(max(dispatch.sequence_number), 0) + 1
    into next_sequence
    from private.mail_v2_episode_dispatches dispatch
    where dispatch.episode_id = episode.id
      and dispatch.dispatch_kind = descriptor.dispatch_kind;
    begin
      insert into private.mail_v2_episode_dispatches(
        episode_id,
        event_id,
        template_key,
        dispatch_kind,
        sequence_number,
        created_at
      ) values (
        episode.id,
        target.id,
        target.template_key,
        descriptor.dispatch_kind,
        next_sequence,
        target.created_at
      );
    exception
      when unique_violation then
        if exists(
          select 1
          from private.mail_v2_episode_dispatches dispatch
          where dispatch.episode_id = episode.id
            and dispatch.event_id = target.id
        ) then
          continue;
        end if;
        raise exception 'MAIL_V2_EPISODE_DISPATCH_EXISTS'
          using errcode = '23505';
    end;
    bound_count := bound_count + 1;
  end loop;
  return bound_count;
end;
$$;

revoke all on function private.bind_mail_v2_event_to_episodes(uuid, boolean)
from public, anon, authenticated, service_role;

create or replace function private.close_mail_v2_episodes_for_scope(
  p_process_key text,
  p_season_id uuid,
  p_scope_type text,
  p_scope_id uuid,
  p_reason_code text,
  p_source_type text,
  p_source_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  target record;
  closed_count integer := 0;
begin
  for target in
    select episode.id
    from private.mail_v2_notification_episodes episode
    where episode.process_key = p_process_key
      and episode.season_id = p_season_id
      and episode.scope_type = p_scope_type
      and episode.scope_id = p_scope_id
      and episode.status = 'open'
    order by episode.id
    for update skip locked
  loop
    if private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      p_reason_code,
      null,
      p_source_type,
      p_source_id,
      null
    ) then
      closed_count := closed_count + 1;
    end if;
  end loop;
  return closed_count;
end;
$$;

revoke all on function private.close_mail_v2_episodes_for_scope(
  text, uuid, text, uuid, text, text, uuid
) from public, anon, authenticated, service_role;

create or replace function private.on_mail_v2_domain_event_episode()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  perform private.bind_mail_v2_event_to_episodes(new.id, false);
  if new.template_key = 'size_confirmed' then
    perform private.close_mail_v2_episodes_for_scope(
      'size_confirmation',
      new.season_id,
      'order',
      new.order_id,
      'size.confirmed',
      'domain_event',
      new.id
    );
  end if;
  return new;
end;
$$;

create trigger mail_v2_domain_events_episode
after insert on private.mail_v2_domain_events
for each row execute function private.on_mail_v2_domain_event_episode();

revoke all on function private.on_mail_v2_domain_event_episode()
from public, anon, authenticated, service_role;

create or replace function private.apply_mail_v2_suppression_to_episodes(
  p_event_id uuid,
  p_reason text,
  p_superseding_event_id uuid default null,
  p_backfill boolean default false
)
returns integer
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target record;
  changed_count integer := 0;
begin
  if p_superseding_event_id is not null then
    perform private.bind_mail_v2_event_to_episodes(
      p_superseding_event_id,
      p_backfill
    );
  end if;
  for target in
    select distinct episode.id, episode.process_key
    from private.mail_v2_episode_dispatches dispatch
    join private.mail_v2_notification_episodes episode
      on episode.id = dispatch.episode_id
    where dispatch.event_id = p_event_id
      and episode.status = 'open'
      and not (
        p_reason = 'superseded_by_back_in_stock'
        and episode.process_key = 'pickup'
        and exists(
          select 1
          from private.mail_v2_episode_dispatches superseding_dispatch
          where superseding_dispatch.episode_id = episode.id
            and superseding_dispatch.event_id = p_superseding_event_id
        )
      )
  loop
    if p_reason = 'retry_exhausted' then
      if private.transition_mail_v2_notification_episode(
        target.id,
        'open',
        'projection.retry_exhausted',
        'projection_retry_exhausted',
        'event_suppression',
        p_event_id,
        null
      ) then
        changed_count := changed_count + 1;
      end if;
    else
      if private.transition_mail_v2_notification_episode(
        target.id,
        'closed',
        'event.' || p_reason,
        null,
        case when p_backfill then 'backfill' else 'event_suppression' end,
        p_event_id,
        null
      ) then
        changed_count := changed_count + 1;
      end if;
    end if;
  end loop;
  return changed_count;
end;
$$;

revoke all on function private.apply_mail_v2_suppression_to_episodes(
  uuid, text, uuid, boolean
) from public, anon, authenticated, service_role;

create or replace function private.on_mail_v2_event_suppression_episode()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  perform private.apply_mail_v2_suppression_to_episodes(
    new.event_id,
    new.reason,
    new.superseding_event_id,
    false
  );
  return new;
end;
$$;

create trigger mail_v2_event_suppressions_episode
after insert on private.mail_v2_event_suppressions
for each row execute function private.on_mail_v2_event_suppression_episode();

revoke all on function private.on_mail_v2_event_suppression_episode()
from public, anon, authenticated, service_role;

create or replace function private.on_mail_v2_payment_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
begin
  if new.status <> 'paid' or new.reconciliation_issue is not null then
    return new;
  end if;
  select * into target_order
  from app.member_orders orders
  where orders.id = new.order_id;
  if not found then
    return new;
  end if;
  perform private.close_mail_v2_episodes_for_scope(
    'payment',
    target_order.season_id,
    'order',
    target_order.id,
    'payment.received',
    'payment',
    new.id
  );
  perform private.close_mail_v2_episodes_for_scope(
    'availability_payment',
    target_order.season_id,
    'order',
    target_order.id,
    'payment.received',
    'payment',
    new.id
  );
  return new;
end;
$$;

create trigger payments_mail_v2_episode_exit
after insert or update of status, reconciliation_issue on app.payments
for each row execute function private.on_mail_v2_payment_episode_exit();

revoke all on function private.on_mail_v2_payment_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_parent_login_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target record;
begin
  if new.last_login_at is null
    or new.last_login_at is not distinct from old.last_login_at
  then
    return new;
  end if;
  for target in
    select episode.id
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'portal_access'
      and episode.parent_account_id = new.id
      and episode.status = 'open'
      and episode.opened_at <= new.last_login_at
    order by episode.id
    for update skip locked
  loop
    perform private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      'portal.login_completed',
      null,
      'parent_login',
      new.id,
      null
    );
  end loop;
  return new;
end;
$$;

create trigger parent_accounts_mail_v2_episode_exit
after update of last_login_at on private.parent_accounts
for each row execute function private.on_parent_login_mail_v2_episode_exit();

revoke all on function private.on_parent_login_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_parent_grant_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_season_id uuid;
begin
  if new.status <> 'revoked' or old.status = 'revoked' then
    return new;
  end if;
  select member_season.season_id into target_season_id
  from app.member_seasons member_season
  where member_season.id = new.member_season_id;
  perform private.close_mail_v2_episodes_for_scope(
    'portal_access',
    target_season_id,
    'member_season',
    new.member_season_id,
    'portal.grant_revoked',
    'portal_grant',
    new.id
  );
  return new;
end;
$$;

create trigger parent_portal_grants_mail_v2_episode_exit
after update of status on private.parent_portal_grants
for each row execute function private.on_parent_grant_mail_v2_episode_exit();

revoke all on function private.on_parent_grant_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_inventory_allocation_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  if new.status = 'reserved' then
    perform private.close_mail_v2_episodes_for_scope(
      'payment_waiting_stock',
      new.season_id,
      'order',
      new.order_id,
      'inventory.reserved',
      'inventory_allocation',
      new.id
    );
    perform private.close_mail_v2_episodes_for_scope(
      'availability_payment',
      new.season_id,
      'order',
      new.order_id,
      'inventory.reserved',
      'inventory_allocation',
      new.id
    );
    return new;
  end if;
  if new.status in ('released', 'fulfilled')
    and not exists(
      select 1
      from app.inventory_allocations allocation
      where allocation.order_line_id = new.order_line_id
        and allocation.status = 'reserved'
    )
  then
    perform private.close_mail_v2_episodes_for_scope(
      'pickup',
      new.season_id,
      'order_line',
      new.order_line_id,
      'pickup.no_reserved_allocation',
      'inventory_allocation',
      new.id
    );
    if not exists(
      select 1
      from app.inventory_allocations allocation
      where allocation.order_id = new.order_id
        and allocation.status = 'reserved'
    ) then
      perform private.close_mail_v2_episodes_for_scope(
        'pickup_reminder',
        new.season_id,
        'order',
        new.order_id,
        'pickup.no_reserved_allocation',
        'inventory_allocation',
        new.id
      );
    end if;
  end if;
  return new;
end;
$$;

create trigger inventory_allocations_mail_v2_episode_exit
after insert or update of status on app.inventory_allocations
for each row execute function
  private.on_inventory_allocation_mail_v2_episode_exit();

revoke all on function private.on_inventory_allocation_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.close_mail_v2_member_season_episodes(
  p_member_season_id uuid,
  p_reason_code text,
  p_source_id uuid
)
returns integer
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target record;
  closed_count integer := 0;
begin
  for target in
    select episode.id
    from private.mail_v2_notification_episodes episode
    where episode.status = 'open'
      and (
        (
          episode.scope_type = 'member_season'
          and episode.scope_id = p_member_season_id
        )
        or (
          episode.scope_type = 'order'
          and episode.scope_id in (
            select orders.id
            from app.member_orders orders
            where orders.member_season_id = p_member_season_id
          )
        )
        or (
          episode.scope_type = 'order_line'
          and episode.scope_id in (
            select line.id
            from app.order_lines line
            join app.member_orders orders on orders.id = line.order_id
            where orders.member_season_id = p_member_season_id
          )
        )
      )
    order by episode.id
    for update skip locked
  loop
    if private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      p_reason_code,
      null,
      'member_season',
      p_source_id,
      null
    ) then
      closed_count := closed_count + 1;
    end if;
  end loop;
  return closed_count;
end;
$$;

revoke all on function private.close_mail_v2_member_season_episodes(
  uuid, text, uuid
) from public, anon, authenticated, service_role;

create or replace function private.on_member_season_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  if new.participation_status <> 'active'
    or new.reconciliation_status <> 'resolved'
  then
    perform private.close_mail_v2_member_season_episodes(
      new.id,
      'member_season.inactive',
      new.id
    );
  end if;
  return new;
end;
$$;

create trigger member_seasons_mail_v2_episode_exit
after update of participation_status, reconciliation_status
on app.member_seasons
for each row execute function
  private.on_member_season_mail_v2_episode_exit();

revoke all on function private.on_member_season_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_member_size_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_member_season_id uuid := case
    when tg_op = 'DELETE' then old.member_season_id
    else new.member_season_id
  end;
  target record;
begin
  for target in
    select orders.id, orders.season_id
    from app.member_orders orders
    where orders.member_season_id = target_member_season_id
  loop
    if private.mail_v2_size_segment(target.id) in ('complete', 'blocked') then
      perform private.close_mail_v2_episodes_for_scope(
        'size_confirmation',
        target.season_id,
        'order',
        target.id,
        'size.segment_complete',
        'size_profile',
        target_member_season_id
      );
    end if;
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger member_article_sizes_mail_v2_episode_exit
after insert or update or delete on app.member_article_sizes
for each row execute function private.on_member_size_mail_v2_episode_exit();

revoke all on function private.on_member_size_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_order_line_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_order_id uuid := case
    when tg_op = 'DELETE' then old.order_id
    else new.order_id
  end;
  source_line_id uuid := case
    when tg_op = 'DELETE' then old.id
    else new.id
  end;
  target_season_id uuid;
  target record;
begin
  select orders.season_id into target_season_id
  from app.member_orders orders
  where orders.id = target_order_id;
  if tg_op = 'DELETE'
    or (tg_op <> 'DELETE' and new.status = 'cancelled')
  then
    perform private.close_mail_v2_episodes_for_scope(
      'shortage',
      target_season_id,
      'order_line',
      source_line_id,
      'order_line.inactive',
      'order_line',
      source_line_id
    );
    perform private.close_mail_v2_episodes_for_scope(
      'pickup',
      target_season_id,
      'order_line',
      source_line_id,
      'order_line.inactive',
      'order_line',
      source_line_id
    );
  end if;
  if not exists(
    select 1
    from app.order_lines line
    where line.order_id = target_order_id
      and line.status <> 'cancelled'
  ) then
    for target in
      select episode.id
      from private.mail_v2_notification_episodes episode
      where episode.season_id = target_season_id
        and episode.scope_type = 'order'
        and episode.scope_id = target_order_id
        and episode.status = 'open'
      order by episode.id
      for update skip locked
    loop
      perform private.transition_mail_v2_notification_episode(
        target.id,
        'closed',
        'order_line.order_inactive',
        null,
        'order_line',
        source_line_id,
        null
      );
    end loop;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger order_lines_mail_v2_episode_exit
after insert or delete or update of status on app.order_lines
for each row execute function private.on_order_line_mail_v2_episode_exit();

revoke all on function private.on_order_line_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_inventory_movement_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target record;
begin
  if (
    select balance.available
    from private.inventory_balance(
      new.season_id,
      new.article_variant_id
    ) balance
  ) > 0 then
    for target in
      select episode.id
      from private.mail_v2_notification_episodes episode
      join app.order_lines line
        on line.id = episode.scope_id
        and line.article_variant_id = new.article_variant_id
      where episode.process_key = 'shortage'
        and episode.season_id = new.season_id
        and episode.scope_type = 'order_line'
        and episode.status = 'open'
      order by episode.id
      for update of episode skip locked
    loop
      perform private.transition_mail_v2_notification_episode(
        target.id,
        'closed',
        'inventory.stock_available',
        null,
        'inventory_movement',
        new.id,
        null
      );
    end loop;
  end if;

  for target in
    select episode.id, episode.scope_id order_id
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'availability_payment'
      and episode.season_id = new.season_id
      and episode.scope_type = 'order'
      and episode.status = 'open'
      and exists(
        select 1
        from app.order_lines line
        where line.order_id = episode.scope_id
          and line.article_variant_id = new.article_variant_id
      )
      and not exists(
        select 1
        from app.order_lines line
        join lateral private.inventory_balance(
          new.season_id,
          line.article_variant_id
        ) balance on true
        where line.order_id = episode.scope_id
          and line.status = 'backorder'
          and line.article_variant_id is not null
          and private.mail_v2_order_line_size_is_valid(line.id)
          and balance.available > 0
          and not exists(
            select 1
            from app.inventory_allocations allocation
            where allocation.order_line_id = line.id
              and allocation.status in ('reserved', 'fulfilled')
          )
      )
    order by episode.id
    for update of episode skip locked
  loop
    perform private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      'inventory.no_free_stock',
      null,
      'inventory_movement',
      new.id,
      null
    );
  end loop;
  return new;
end;
$$;

create trigger inventory_movements_mail_v2_episode_exit
after insert on app.inventory_movements
for each row execute function
  private.on_inventory_movement_mail_v2_episode_exit();

revoke all on function private.on_inventory_movement_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_season_mail_v2_episode_exit()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target record;
begin
  if new.status = 'open' then
    return new;
  end if;
  for target in
    select episode.id
    from private.mail_v2_notification_episodes episode
    where episode.season_id = new.id
      and episode.status = 'open'
    order by episode.id
    for update skip locked
  loop
    perform private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      'season.inactive',
      null,
      'season',
      new.id,
      null
    );
  end loop;
  return new;
end;
$$;

create trigger seasons_mail_v2_episode_exit
after update of status on app.seasons
for each row execute function private.on_season_mail_v2_episode_exit();

revoke all on function private.on_season_mail_v2_episode_exit()
from public, anon, authenticated, service_role;

create or replace function private.on_email_job_mail_v2_episode_state()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target record;
  failure_reason text;
  source_kind text := 'email_job';
  actor uuid;
  can_clear boolean := false;
begin
  if new.context_kind <> 'mail_v2' then
    return new;
  end if;
  failure_reason := case
    when new.delivery_status = 'bounced' then 'delivery_bounced'
    when new.delivery_status = 'dropped' then 'delivery_dropped'
    when new.delivery_status = 'failed' then 'delivery_failed'
    when new.status = 'failed'
      and coalesce(new.last_error, '') not in (
        'eligibility_changed_before_send',
        'access_inactive_before_send'
      )
    then 'delivery_failed'
    when new.status = 'delivery_uncertain' then 'delivery_uncertain'
  end;
  if failure_reason is not null then
    for target in
      select distinct episode.id
      from private.mail_v2_projection_batches batch
      join private.mail_v2_projections projection
        on projection.projection_batch_id = batch.id
      join private.mail_v2_episode_dispatches dispatch
        on dispatch.event_id = projection.event_id
      join private.mail_v2_notification_episodes episode
        on episode.id = dispatch.episode_id
      where batch.email_job_id = new.id
        and episode.status = 'open'
    loop
      perform private.transition_mail_v2_notification_episode(
        target.id,
        'open',
        'delivery.blocked',
        failure_reason,
        'email_job',
        new.id,
        null
      );
    end loop;
    return new;
  end if;

  if new.status in ('retry', 'sent')
    and (
      old.status in ('failed', 'delivery_uncertain')
      or old.delivery_status in ('bounced', 'dropped', 'failed')
    )
  then
    if new.recovered_at is distinct from old.recovered_at
      and new.recovered_at is not null
      and new.recovered_by is not null
    then
      actor := new.recovered_by;
      can_clear := true;
    elsif exists(
      select 1
      from app.email_events provider_event
      where provider_event.email_job_id = new.id
        and provider_event.event_type = coalesce(
          new.delivery_status,
          provider_event.event_type
        )
    ) then
      source_kind := 'provider_event';
      can_clear := true;
    end if;
  end if;
  if not can_clear then
    return new;
  end if;

  for target in
    select distinct episode.id
    from private.mail_v2_projection_batches batch
    join private.mail_v2_projections projection
      on projection.projection_batch_id = batch.id
    join private.mail_v2_episode_dispatches dispatch
      on dispatch.event_id = projection.event_id
    join private.mail_v2_notification_episodes episode
      on episode.id = dispatch.episode_id
    where batch.email_job_id = new.id
      and episode.status = 'open'
      and episode.blocked_reason is not null
      and not exists(
        select 1
        from private.mail_v2_episode_dispatches other_dispatch
        join private.mail_v2_projections other_projection
          on other_projection.event_id = other_dispatch.event_id
        join private.mail_v2_projection_batches other_batch
          on other_batch.id = other_projection.projection_batch_id
        join private.email_jobs other_job
          on other_job.id = other_batch.email_job_id
        where other_dispatch.episode_id = episode.id
          and other_job.id <> new.id
          and (
            other_job.status in ('failed', 'delivery_uncertain')
            or other_job.delivery_status in (
              'bounced',
              'dropped',
              'failed'
            )
          )
      )
  loop
    perform private.transition_mail_v2_notification_episode(
      target.id,
      'open',
      'delivery.recovered',
      null,
      source_kind,
      new.id,
      actor
    );
  end loop;
  return new;
end;
$$;

create trigger email_jobs_mail_v2_episode_state
after update of
  status,
  delivery_status,
  recovered_at,
  recovered_by
on private.email_jobs
for each row execute function private.on_email_job_mail_v2_episode_state();

revoke all on function private.on_email_job_mail_v2_episode_state()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_notification_episode_is_current(
  p_episode_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = private, app, pg_temp
as $$
declare
  target private.mail_v2_notification_episodes%rowtype;
  target_order app.member_orders%rowtype;
  target_line app.order_lines%rowtype;
  payment_state text;
begin
  select * into target
  from private.mail_v2_notification_episodes episode
  where episode.id = p_episode_id;
  if not found or target.status <> 'open' then
    return false;
  end if;
  if target.process_key = 'internal_email_failure' then
    return exists(
      select 1
      from private.email_jobs job
      where job.id = target.scope_id
        and (
          job.status in ('failed', 'delivery_uncertain')
          or job.delivery_status in ('bounced', 'dropped', 'failed')
        )
    );
  end if;
  if target.process_key = 'portal_access' then
    return exists(
      select 1
      from app.member_seasons member_season
      join private.parent_portal_grants grant_row
        on grant_row.member_season_id = member_season.id
        and grant_row.parent_account_id = target.parent_account_id
        and grant_row.status = 'active'
      join private.parent_accounts account
        on account.id = target.parent_account_id
      where member_season.id = target.scope_id
        and member_season.season_id = target.season_id
        and member_season.participation_status = 'active'
        and member_season.reconciliation_status = 'resolved'
        and (
          account.last_login_at is null
          or account.last_login_at < target.opened_at
        )
    );
  end if;

  if target.scope_type = 'order' then
    select * into target_order
    from app.member_orders orders
    where orders.id = target.scope_id;
  elsif target.scope_type = 'order_line' then
    select * into target_line
    from app.order_lines line
    where line.id = target.scope_id;
    select * into target_order
    from app.member_orders orders
    where orders.id = target_line.order_id;
  end if;
  if target_order.id is null or not exists(
    select 1
    from app.member_seasons member_season
    join private.parent_portal_grants grant_row
      on grant_row.member_season_id = member_season.id
      and grant_row.parent_account_id = target.parent_account_id
      and grant_row.status = 'active'
    where member_season.id = target_order.member_season_id
      and member_season.season_id = target.season_id
      and member_season.participation_status = 'active'
      and member_season.reconciliation_status = 'resolved'
  ) then
    return false;
  end if;
  payment_state := private.mail_v2_payment_state(target_order.id);

  if target.process_key = 'size_confirmation' then
    return private.mail_v2_size_segment(target_order.id) in ('fill', 'review');
  end if;
  if target.process_key = 'payment' then
    return payment_state = 'unpaid';
  end if;
  if target.process_key = 'payment_waiting_stock' then
    return payment_state = 'paid'
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_id = target_order.id
          and allocation.status = 'reserved'
      )
      and exists(
        select 1
        from app.order_lines line
        where line.order_id = target_order.id
          and line.status = 'backorder'
          and not exists(
            select 1
            from app.inventory_allocations allocation
            where allocation.order_line_id = line.id
              and allocation.status in ('reserved', 'fulfilled')
          )
      );
  end if;
  if target.process_key = 'availability_payment' then
    return payment_state = 'unpaid'
      and exists(
        select 1
        from app.order_lines line
        join lateral private.inventory_balance(
          target.season_id,
          line.article_variant_id
        ) balance on true
        where line.order_id = target_order.id
          and line.status = 'backorder'
          and line.article_variant_id is not null
          and private.mail_v2_order_line_size_is_valid(line.id)
          and balance.available > 0
          and not exists(
            select 1
            from app.inventory_allocations allocation
            where allocation.order_line_id = line.id
              and allocation.status in ('reserved', 'fulfilled')
          )
      );
  end if;
  if target.process_key = 'shortage' then
    return payment_state = 'paid'
      and target_line.id is not null
      and target_line.status = 'backorder'
      and target_line.article_variant_id is not null
      and private.mail_v2_order_line_size_is_valid(target_line.id)
      and (
        select balance.available = 0
        from private.inventory_balance(
          target.season_id,
          target_line.article_variant_id
        ) balance
      )
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = target_line.id
          and allocation.status in ('reserved', 'fulfilled')
      );
  end if;
  if target.process_key in ('pickup', 'pickup_reminder') then
    return payment_state = 'paid'
      and exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_id = target_order.id
          and allocation.status = 'reserved'
          and (
            target.process_key = 'pickup_reminder'
            or allocation.order_line_id = target_line.id
          )
      );
  end if;
  return false;
end;
$$;

revoke all on function private.mail_v2_notification_episode_is_current(uuid)
from public, anon, authenticated, service_role;

do $$
declare
  item record;
begin
  for item in
    select 'event' item_type, event.id item_id, event.created_at
    from private.mail_v2_domain_events event
    union all
    select 'suppression', suppression.event_id, suppression.created_at
    from private.mail_v2_event_suppressions suppression
    order by created_at, item_type, item_id
  loop
    if item.item_type = 'event' then
      perform private.bind_mail_v2_event_to_episodes(item.item_id, true);
      if exists(
        select 1
        from private.mail_v2_domain_events event
        where event.id = item.item_id
          and event.template_key = 'size_confirmed'
      ) then
        perform private.close_mail_v2_episodes_for_scope(
          'size_confirmation',
          (
            select event.season_id
            from private.mail_v2_domain_events event
            where event.id = item.item_id
          ),
          'order',
          (
            select event.order_id
            from private.mail_v2_domain_events event
            where event.id = item.item_id
          ),
          'size.confirmed',
          'backfill',
          item.item_id
        );
      end if;
    else
      perform private.apply_mail_v2_suppression_to_episodes(
        item.item_id,
        (
          select suppression.reason
          from private.mail_v2_event_suppressions suppression
          where suppression.event_id = item.item_id
        ),
        (
          select suppression.superseding_event_id
          from private.mail_v2_event_suppressions suppression
          where suppression.event_id = item.item_id
        ),
        true
      );
    end if;
  end loop;
end;
$$;

do $$
declare
  target record;
begin
  for target in
    select episode.id, episode.opening_event_id
    from private.mail_v2_notification_episodes episode
    where episode.status = 'open'
      and not private.mail_v2_notification_episode_is_current(episode.id)
    order by episode.id
    for update skip locked
  loop
    perform private.transition_mail_v2_notification_episode(
      target.id,
      'closed',
      'backfill.current_state_terminal',
      null,
      'backfill',
      target.opening_event_id,
      null
    );
  end loop;
end;
$$;

do $$
declare
  expected_bindings bigint;
  actual_bindings bigint;
  missing_bindings bigint;
  duplicate_bindings bigint;
  context_mismatches bigint;
  terminal_open_episodes bigint;
  missing_open_transitions bigint;
begin
  with expected as (
    select
      event.id event_id,
      event.parent_account_id,
      event.season_id,
      descriptor.process_key,
      descriptor.scope_type,
      descriptor.scope_id
    from private.mail_v2_domain_events event
    cross join lateral private.mail_v2_episode_descriptors(event.id)
      descriptor
  ),
  actual as (
    select
      expected.event_id,
      expected.process_key,
      expected.scope_type,
      expected.scope_id,
      count(episode.id) binding_count
    from expected
    left join private.mail_v2_episode_dispatches dispatch
      on dispatch.event_id = expected.event_id
    left join private.mail_v2_notification_episodes episode
      on episode.id = dispatch.episode_id
      and episode.process_key = expected.process_key
      and episode.scope_type = expected.scope_type
      and episode.scope_id = expected.scope_id
      and episode.season_id = expected.season_id
      and episode.parent_account_id is not distinct from
        expected.parent_account_id
    group by
      expected.event_id,
      expected.process_key,
      expected.scope_type,
      expected.scope_id
  )
  select
    count(*),
    coalesce(sum(binding_count), 0),
    count(*) filter (where binding_count = 0),
    count(*) filter (where binding_count > 1)
  into
    expected_bindings,
    actual_bindings,
    missing_bindings,
    duplicate_bindings
  from actual;

  select count(*) into context_mismatches
  from private.mail_v2_episode_dispatches dispatch
  join private.mail_v2_domain_events event
    on event.id = dispatch.event_id
  join private.mail_v2_notification_episodes episode
    on episode.id = dispatch.episode_id
  where episode.season_id <> event.season_id
    or episode.parent_account_id is distinct from event.parent_account_id
    or dispatch.template_key <> event.template_key
    or not exists(
      select 1
      from private.mail_v2_episode_descriptors(event.id) descriptor
      where descriptor.process_key = episode.process_key
        and descriptor.scope_type = episode.scope_type
        and descriptor.scope_id = episode.scope_id
    );

  select count(*) into terminal_open_episodes
  from private.mail_v2_notification_episodes episode
  where episode.status = 'open'
    and not private.mail_v2_notification_episode_is_current(episode.id);

  select count(*) into missing_open_transitions
  from private.mail_v2_notification_episodes episode
  where not exists(
    select 1
    from private.mail_v2_episode_transitions transition
    where transition.episode_id = episode.id
      and transition.from_status is null
      and transition.to_status = 'open'
  );

  if missing_bindings <> 0
    or duplicate_bindings <> 0
    or context_mismatches <> 0
    or terminal_open_episodes <> 0
    or missing_open_transitions <> 0
  then
    raise exception 'MAIL_V2_EPISODE_RECONCILIATION_FAILED'
      using errcode = '23514';
  end if;

  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260802276000_mail_v2_notification_episodes',
    'passed',
    jsonb_build_object(
      'events', (
        select count(*) from private.mail_v2_domain_events
      ),
      'expectedBindings', expected_bindings,
      'actualBindings', actual_bindings,
      'episodes', (
        select count(*) from private.mail_v2_notification_episodes
      ),
      'openEpisodes', (
        select count(*)
        from private.mail_v2_notification_episodes
        where status = 'open'
      ),
      'blockedEpisodes', (
        select count(*)
        from private.mail_v2_notification_episodes
        where status = 'open' and blocked_reason is not null
      )
    )
  )
  on conflict (migration_key) do update
  set status = excluded.status,
      metrics = excluded.metrics,
      reconciled_at = timezone('utc', now());
end;
$$;

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
  with descriptor as (
    select
      case
        when p_template_key in (
          'size_fill_request',
          'size_review_request'
        ) then 'size_confirmation'
        when p_template_key = 'payment_request' then 'payment'
        when p_template_key = 'available_payment_required'
        then 'availability_payment'
        when p_template_key = 'out_of_stock' then 'shortage'
      end process_key,
      case when p_template_key = 'out_of_stock'
        then 'order_line' else 'order' end scope_type,
      case when p_template_key = 'out_of_stock'
        then p_order_line_id else p_order_id end scope_id
  )
  select exists(
    select 1
    from descriptor
    join private.mail_v2_notification_episodes episode
      on episode.process_key = descriptor.process_key
      and episode.parent_account_id = p_parent_account_id
      and episode.scope_type = descriptor.scope_type
      and episode.scope_id = descriptor.scope_id
      and episode.status = 'open'
    join private.mail_v2_episode_dispatches dispatch
      on dispatch.episode_id = episode.id
      and dispatch.template_key = p_template_key
  );
$$;

revoke all on function private.mail_v2_campaign_current_episode_exists(
  text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

comment on table private.mail_v2_notification_episodes is
  'Durable process episodes; blocked delivery remains in the same episode until evidenced recovery or domain exit.';
comment on table private.mail_v2_episode_dispatches is
  'Immutable event-to-episode dispatch ledger used for campaign dedupe.';
comment on function private.mail_v2_campaign_current_episode_exists(
  text, uuid, uuid, uuid
) is
  'Checks durable open episodes instead of inferring a process episode from mutable current state.';

select pg_notify('pgrst', 'reload schema');
