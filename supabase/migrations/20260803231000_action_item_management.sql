-- Safe staff management for the uniform action-item ledger.
--
-- Action items remain non-destructive domain facts. Normal staff can only read
-- through RLS and mutate through revision-checked, audited RPCs. The tenant is
-- implicit and fixed to Duindorp SV; every item remains bound to one season.

alter table app.action_items
  add column revision integer not null default 1
    check (revision > 0),
  add column assigned_at timestamptz,
  add column assigned_by uuid,
  add column started_at timestamptz,
  add column started_by uuid;

alter table app.action_items
  add constraint action_items_owner_user_fkey
    foreign key (owner_user_id)
    references app.staff_profiles(auth_user_id)
    on delete restrict
    not valid,
  add constraint action_items_assigned_by_fkey
    foreign key (assigned_by)
    references app.staff_profiles(auth_user_id)
    on delete restrict
    not valid,
  add constraint action_items_started_by_fkey
    foreign key (started_by)
    references app.staff_profiles(auth_user_id)
    on delete restrict
    not valid,
  add constraint action_items_started_pair_check check (
    (started_at is null and started_by is null)
    or (started_at is not null and started_by is not null)
  ) not valid;

-- Existing owner values were never writable through the public API. Validation
-- deliberately blocks promotion if an out-of-band owner no longer maps to a
-- staff profile instead of silently discarding the assignment.
alter table app.action_items validate constraint action_items_owner_user_fkey;
alter table app.action_items validate constraint action_items_assigned_by_fkey;
alter table app.action_items validate constraint action_items_started_by_fkey;
alter table app.action_items validate constraint action_items_started_pair_check;

create index action_items_owner_queue_idx
  on app.action_items(season_id, owner_user_id, status, due_at, opened_at)
  where status in ('open', 'in_progress');

create or replace function private.bump_action_item_revision()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if old.revision >= 2147483647 then
    raise exception 'ACTION_ITEM_REVISION_EXHAUSTED' using errcode = '40001';
  end if;
  new.revision := old.revision + 1;
  return new;
end;
$$;

create trigger action_items_bump_revision
before update on app.action_items
for each row execute function private.bump_action_item_revision();

revoke all on function private.bump_action_item_revision()
from public, anon, authenticated, service_role;

create or replace function private.action_item_management_context(
  p_action_item_id uuid,
  p_expected_revision integer
)
returns app.action_items
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  role_name app.staff_role := app.staff_role();
  target app.action_items%rowtype;
begin
  if p_action_item_id is null
    or p_expected_revision is null
    or p_expected_revision < 1
  then
    raise exception 'ACTION_ITEM_MUTATION_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.action_items item
  where item.id = p_action_item_id
  for update;

  if not found then
    raise exception 'ACTION_ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if role_name = 'kledingcommissie' and target.visibility <> 'operations' then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if target.revision <> p_expected_revision then
    raise exception 'ACTION_ITEM_REVISION_CONFLICT' using errcode = '40001';
  end if;
  return target;
end;
$$;

revoke all on function private.action_item_management_context(uuid, integer)
from public, anon, authenticated, service_role;

create or replace function private.action_item_result(
  p_action_item_id uuid,
  p_reused boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'id', item.id,
    'status', item.status::text,
    'ownerUserId', item.owner_user_id,
    'revision', item.revision,
    'updatedAt', item.updated_at,
    'reused', p_reused
  )
  from app.action_items item
  where item.id = p_action_item_id;
$$;

revoke all on function private.action_item_result(uuid, boolean)
from public, anon, authenticated, service_role;

create or replace function app.assign_action_item(
  p_action_item_id uuid,
  p_expected_revision integer,
  p_owner_user_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  role_name app.staff_role := app.staff_role();
  target app.action_items%rowtype;
  owner_role app.staff_role;
begin
  target := private.action_item_management_context(
    p_action_item_id,
    p_expected_revision
  );

  if target.status in ('resolved', 'dismissed') then
    raise exception 'ACTION_ITEM_ALREADY_CLOSED' using errcode = '40001';
  end if;
  if p_owner_user_id is null and target.status = 'in_progress' then
    raise exception 'ACTION_ITEM_ACTIVE_OWNER_REQUIRED' using errcode = '23514';
  end if;

  if p_owner_user_id is not null then
    select profile.role into owner_role
    from app.staff_profiles profile
    where profile.auth_user_id = p_owner_user_id
      and profile.active
      and profile.role in ('beheerder', 'kledingcommissie');

    if owner_role is null
      or (target.visibility = 'admin_only' and owner_role <> 'beheerder')
    then
      raise exception 'ACTION_ITEM_OWNER_INVALID' using errcode = '23514';
    end if;
  end if;

  if target.owner_user_id is not distinct from p_owner_user_id then
    return private.action_item_result(target.id, true);
  end if;

  update app.action_items
  set owner_user_id = p_owner_user_id,
      assigned_at = timezone('utc', now()),
      assigned_by = actor
  where id = target.id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  select
    actor,
    'action_item.assigned',
    'action_item',
    item.id,
    jsonb_build_object(
      'type', item.type,
      'seasonId', item.season_id,
      'previousOwnerUserId', target.owner_user_id,
      'ownerUserId', item.owner_user_id,
      'previousRevision', target.revision,
      'revision', item.revision,
      'unassigned', item.owner_user_id is null
    ),
    p_correlation_id
  from app.action_items item
  where item.id = target.id;

  return private.action_item_result(target.id);
end;
$$;

create or replace function app.start_action_item(
  p_action_item_id uuid,
  p_expected_revision integer,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  target app.action_items%rowtype;
begin
  target := private.action_item_management_context(
    p_action_item_id,
    p_expected_revision
  );

  if target.status in ('resolved', 'dismissed') then
    raise exception 'ACTION_ITEM_ALREADY_CLOSED' using errcode = '40001';
  end if;
  if target.status <> 'open' then
    raise exception 'ACTION_ITEM_ALREADY_STARTED' using errcode = '40001';
  end if;
  if target.owner_user_id is not null and target.owner_user_id <> actor then
    raise exception 'ACTION_ITEM_ASSIGNED_TO_OTHER' using errcode = '42501';
  end if;

  update app.action_items
  set status = 'in_progress',
      owner_user_id = coalesce(owner_user_id, actor),
      assigned_at = case
        when owner_user_id is null then timezone('utc', now())
        else assigned_at
      end,
      assigned_by = case
        when owner_user_id is null then actor
        else assigned_by
      end,
      started_at = timezone('utc', now()),
      started_by = actor
  where id = target.id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  select
    actor,
    'action_item.started',
    'action_item',
    item.id,
    jsonb_build_object(
      'type', item.type,
      'seasonId', item.season_id,
      'ownerUserId', item.owner_user_id,
      'previousRevision', target.revision,
      'revision', item.revision
    ),
    p_correlation_id
  from app.action_items item
  where item.id = target.id;

  return private.action_item_result(target.id);
end;
$$;

create or replace function private.close_action_item_v2(
  p_action_item_id uuid,
  p_expected_revision integer,
  p_resolution app.action_item_status,
  p_reason text,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  target app.action_items%rowtype;
begin
  if p_resolution not in ('resolved', 'dismissed')
    or p_reason is null
    or length(btrim(p_reason)) not between 3 and 500
  then
    raise exception 'ACTION_ITEM_RESOLUTION_INVALID' using errcode = '22023';
  end if;

  target := private.action_item_management_context(
    p_action_item_id,
    p_expected_revision
  );
  if target.status in ('resolved', 'dismissed') then
    raise exception 'ACTION_ITEM_ALREADY_CLOSED' using errcode = '40001';
  end if;

  update app.action_items
  set status = p_resolution,
      resolved_at = timezone('utc', now()),
      resolved_by = actor,
      resolution_reason = btrim(p_reason),
      resolution_source = 'staff'
  where id = target.id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  select
    actor,
    case
      when p_resolution = 'resolved' then 'action_item.resolved'
      else 'action_item.dismissed'
    end,
    'action_item',
    item.id,
    jsonb_build_object(
      'type', item.type,
      'seasonId', item.season_id,
      'previousStatus', target.status::text,
      'previousRevision', target.revision,
      'revision', item.revision
    ),
    p_correlation_id
  from app.action_items item
  where item.id = target.id;

  return private.action_item_result(target.id);
end;
$$;

revoke all on function private.close_action_item_v2(
  uuid, integer, app.action_item_status, text, uuid
) from public, anon, authenticated, service_role;

create or replace function app.resolve_action_item_v2(
  p_action_item_id uuid,
  p_expected_revision integer,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language sql
security definer
set search_path = app, private, pg_temp
as $$
  select private.close_action_item_v2(
    p_action_item_id,
    p_expected_revision,
    'resolved',
    p_reason,
    p_correlation_id
  );
$$;

create or replace function app.dismiss_action_item(
  p_action_item_id uuid,
  p_expected_revision integer,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language sql
security definer
set search_path = app, private, pg_temp
as $$
  select private.close_action_item_v2(
    p_action_item_id,
    p_expected_revision,
    'dismissed',
    p_reason,
    p_correlation_id
  );
$$;

-- The legacy closer remains available for the already released package-size
-- compatibility workflows. New management clients use the revision-checked v2
-- closer below; the legacy implementation itself still serializes and rejects
-- a conflicting terminal transition under a row lock.

revoke all on function app.assign_action_item(uuid, integer, uuid, uuid)
from public, anon, service_role;
revoke all on function app.start_action_item(uuid, integer, uuid)
from public, anon, service_role;
revoke all on function app.resolve_action_item_v2(uuid, integer, text, uuid)
from public, anon, service_role;
revoke all on function app.dismiss_action_item(uuid, integer, text, uuid)
from public, anon, service_role;

grant execute on function app.assign_action_item(uuid, integer, uuid, uuid)
to authenticated;
grant execute on function app.start_action_item(uuid, integer, uuid)
to authenticated;
grant execute on function app.resolve_action_item_v2(uuid, integer, text, uuid)
to authenticated;
grant execute on function app.dismiss_action_item(uuid, integer, text, uuid)
to authenticated;

create or replace function app.get_action_item_workspace(
  p_season_id uuid default null,
  p_status app.action_item_status default null,
  p_severity app.action_item_severity default null,
  p_owner_user_id uuid default null,
  p_only_unassigned boolean default false,
  p_offset integer default 0,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  role_name app.staff_role := app.staff_role();
  target_season_id uuid;
  result jsonb;
begin
  if p_offset is null
    or p_offset < 0
    or p_limit is null
    or p_limit not between 1 and 100
    or p_only_unassigned is null
    or (p_only_unassigned and p_owner_user_id is not null)
  then
    raise exception 'ACTION_ITEM_QUERY_INVALID' using errcode = '22023';
  end if;

  target_season_id := coalesce(
    p_season_id,
    (
      select settings.active_season_id
      from app.app_settings settings
      where settings.id = true
    )
  );
  if target_season_id is null
    or not exists(
      select 1 from app.seasons season where season.id = target_season_id
    )
  then
    raise exception 'ACTION_ITEM_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  with visible as (
    select item.*
    from app.action_items item
    where item.season_id = target_season_id
      and (role_name = 'beheerder' or item.visibility = 'operations')
  ),
  filtered as (
    select item.*
    from visible item
    where (p_status is null or item.status = p_status)
      and (p_severity is null or item.severity = p_severity)
      and (p_owner_user_id is null or item.owner_user_id = p_owner_user_id)
      and (not p_only_unassigned or item.owner_user_id is null)
  ),
  page as (
    select item.*
    from filtered item
    order by
      case item.status when 'open' then 1 when 'in_progress' then 2 else 3 end,
      case item.severity when 'critical' then 1 when 'warning' then 2 else 3 end,
      item.due_at nulls last,
      item.opened_at,
      item.id
    offset p_offset
    limit p_limit
  )
  select jsonb_build_object(
    'tenantKey', 'duindorp-sv',
    'activeSeason', (
      select jsonb_build_object('id', season.id, 'name', season.name)
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
    ),
    'selectedSeason', (
      select jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'status', season.status::text
      )
      from app.seasons season
      where season.id = target_season_id
    ),
    'seasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'status', season.status::text,
        'active', season.id = settings.active_season_id
      ) order by season.starts_on desc nulls last, season.name desc)
      from app.seasons season
      cross join app.app_settings settings
      where settings.id = true
    ), '[]'::jsonb),
    'statusCounts', jsonb_build_object(
      'open', (select count(*) from visible item where item.status = 'open'),
      'inProgress', (select count(*) from visible item where item.status = 'in_progress'),
      'resolved', (select count(*) from visible item where item.status = 'resolved'),
      'dismissed', (select count(*) from visible item where item.status = 'dismissed')
    ),
    'ownerOptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', profile.auth_user_id,
        'displayName', profile.display_name,
        'role', profile.role::text
      ) order by lower(profile.display_name), profile.auth_user_id)
      from app.staff_profiles profile
      where profile.active
        and profile.role in ('beheerder', 'kledingcommissie')
    ), '[]'::jsonb),
    'viewer', jsonb_build_object(
      'userId', actor,
      'role', role_name::text
    ),
    'offset', p_offset,
    'limit', p_limit,
    'total', (select count(*) from filtered),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', page.id,
        'type', page.type,
        'seasonId', page.season_id,
        'objectType', page.object_type,
        'objectId', page.object_id,
        'sourceType', page.source_type,
        'sourceId', page.source_id,
        'episode', page.episode,
        'severity', page.severity::text,
        'status', page.status::text,
        'visibility', page.visibility::text,
        'reasonCode', page.reason_code,
        'safeContext', page.safe_context,
        'ownerUserId', page.owner_user_id,
        'ownerDisplayName', owner_profile.display_name,
        'openedAt', page.opened_at,
        'lastSeenAt', page.last_seen_at,
        'dueAt', page.due_at,
        'assignedAt', page.assigned_at,
        'startedAt', page.started_at,
        'resolvedAt', page.resolved_at,
        'resolutionReason', page.resolution_reason,
        'revision', page.revision,
        'updatedAt', page.updated_at,
        'actions', jsonb_build_object(
          'canAssign', page.status in ('open', 'in_progress'),
          'canStart', page.status = 'open'
            and (page.owner_user_id is null or page.owner_user_id = actor),
          'canResolve', page.status in ('open', 'in_progress'),
          'canDismiss', page.status in ('open', 'in_progress')
        )
      ) order by
        case page.status when 'open' then 1 when 'in_progress' then 2 else 3 end,
        case page.severity when 'critical' then 1 when 'warning' then 2 else 3 end,
        page.due_at nulls last,
        page.opened_at,
        page.id)
      from page
      left join app.staff_profiles owner_profile
        on owner_profile.auth_user_id = page.owner_user_id
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function app.get_action_item_workspace(
  uuid, app.action_item_status, app.action_item_severity, uuid, boolean, integer, integer
) from public, anon, service_role;
grant execute on function app.get_action_item_workspace(
  uuid, app.action_item_status, app.action_item_severity, uuid, boolean, integer, integer
) to authenticated;

notify pgrst, 'reload schema';
