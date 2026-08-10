-- Nullable Sportlink identity compatibility and the uniform action-item ledger.
--
-- A member may legitimately have no Sportlink relation number or parent e-mail.
-- No placeholder identity is generated. DOB remains in the private identity
-- table and is never copied into action context, audit metadata or broad RLS.

alter table app.members
  alter column relation_number drop not null,
  alter column email drop not null;

-- The previous compatibility trigger assumes a non-empty relation number.
-- DDL holds the table lock during this one-time canonicalization; re-enable it
-- only after its null-safe replacement below is installed.
alter table app.members disable trigger members_phase_b_compatibility;

do $$
begin
  if exists(
    select 1
    from app.members member
    where nullif(btrim(member.relation_number), '') is not null
    group by upper(btrim(member.relation_number))
    having count(*) > 1
  ) then
    raise exception 'MEMBER_RELATION_NORMALIZATION_CONFLICT' using errcode = '23505';
  end if;
end;
$$;

update app.members
set relation_number = nullif(btrim(relation_number), ''),
    email = lower(nullif(btrim(email), ''))
where relation_number is distinct from nullif(btrim(relation_number), '')
   or email is distinct from lower(nullif(btrim(email), ''));

delete from app.member_external_identities identity_row
using app.members member
where identity_row.member_id = member.id
  and identity_row.issuer = 'sportlink'
  and identity_row.external_id_normalized = ''
  and member.relation_number is null;

alter table app.members
  add constraint members_optional_relation_number_check check (
    relation_number is null
    or (
      relation_number = btrim(relation_number)
      and length(relation_number) between 1 and 120
      and relation_number !~ '[[:cntrl:]]'
    )
  ) not valid,
  add constraint members_optional_email_check check (
    email is null
    or (
      email = lower(btrim(email))
      and length(email) between 1 and 320
      and email !~ '[[:cntrl:]]'
    )
  ) not valid;

alter table app.members validate constraint members_optional_relation_number_check;
alter table app.members validate constraint members_optional_email_check;

create or replace function app.normalize_member_optional_identity()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  new.relation_number := nullif(btrim(new.relation_number), '');
  new.email := lower(nullif(btrim(new.email), ''));
  return new;
end;
$$;

create trigger members_normalize_optional_identity
before insert or update of relation_number, email on app.members
for each row execute function app.normalize_member_optional_identity();

revoke all on function app.normalize_member_optional_identity()
from public, anon, authenticated, service_role;

create trigger member_sensitive_identity_touch_updated_at
before update on private.member_sensitive_identity
for each row execute function app.touch_updated_at();

create trigger member_seasons_touch_updated_at
before update on app.member_seasons
for each row execute function app.touch_updated_at();

create or replace function private.ensure_member_season(
  p_member_id uuid,
  p_season_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result uuid;
  active_season uuid;
  target_member app.members%rowtype;
  is_current boolean;
  member_found boolean;
begin
  if p_member_id is null or p_season_id is null then
    raise exception 'MEMBER_SEASON_INPUT_INVALID' using errcode = '22023';
  end if;

  select active_season_id into active_season
  from app.app_settings where id = true;
  is_current := active_season is not distinct from p_season_id;

  select * into target_member
  from app.members member
  where member.id = p_member_id;
  member_found := found;

  insert into app.member_seasons(
    member_id,
    season_id,
    team_name,
    participation_status,
    reconciliation_status,
    source_import_batch_id
  )
  values(
    p_member_id,
    p_season_id,
    case when member_found and is_current then target_member.team else null end,
    case
      when not member_found or not is_current then 'unknown'::app.member_season_status
      when target_member.active_for_season then 'active'::app.member_season_status
      else 'inactive'::app.member_season_status
    end,
    case
      when member_found and is_current then 'resolved'::app.member_season_reconciliation
      else 'legacy_unknown'::app.member_season_reconciliation
    end,
    case when member_found and is_current then target_member.imported_from_batch_id else null end
  )
  on conflict (member_id, season_id) do update
  set team_name = case
        when excluded.reconciliation_status = 'resolved' then excluded.team_name
        else app.member_seasons.team_name
      end,
      participation_status = case
        when excluded.reconciliation_status = 'resolved' then excluded.participation_status
        else app.member_seasons.participation_status
      end,
      reconciliation_status = case
        when excluded.reconciliation_status = 'resolved' then excluded.reconciliation_status
        else app.member_seasons.reconciliation_status
      end,
      source_import_batch_id = coalesce(
        excluded.source_import_batch_id,
        app.member_seasons.source_import_batch_id
      ),
      updated_at = case
        when excluded.reconciliation_status = 'resolved' and (
          app.member_seasons.team_name is distinct from excluded.team_name
          or app.member_seasons.participation_status is distinct from excluded.participation_status
          or app.member_seasons.reconciliation_status is distinct from excluded.reconciliation_status
          or (
            excluded.source_import_batch_id is not null
            and app.member_seasons.source_import_batch_id is distinct from excluded.source_import_batch_id
          )
        ) then timezone('utc', now())
        else app.member_seasons.updated_at
      end
  returning id into result;
  return result;
end;
$$;

create or replace function app.sync_member_phase_b_compatibility()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  active_season uuid;
  existing_external app.member_external_identities%rowtype;
  normalized_external text;
begin
  insert into private.member_sensitive_identity(member_id)
  values(new.id)
  on conflict (member_id) do nothing;

  if nullif(btrim(new.relation_number), '') is not null then
    normalized_external := upper(btrim(new.relation_number));
    select * into existing_external
    from app.member_external_identities identity_row
    where identity_row.member_id = new.id
      and identity_row.issuer = 'sportlink'
      and identity_row.is_primary
    for update;

    if found and existing_external.external_id_normalized <> normalized_external then
      raise exception 'MEMBER_EXTERNAL_IDENTITY_CHANGE_REQUIRES_WORKFLOW'
        using errcode = '23505';
    end if;

    insert into app.member_external_identities(
      member_id,
      issuer,
      external_id,
      external_id_normalized,
      source_import_batch_id
    )
    values(
      new.id,
      'sportlink',
      btrim(new.relation_number),
      normalized_external,
      new.imported_from_batch_id
    )
    on conflict (issuer, external_id_normalized) do update
    set external_id = excluded.external_id,
        source_import_batch_id = coalesce(
          excluded.source_import_batch_id,
          app.member_external_identities.source_import_batch_id
        )
    where app.member_external_identities.member_id = excluded.member_id;

    if not found then
      raise exception 'MEMBER_EXTERNAL_IDENTITY_CONFLICT' using errcode = '23505';
    end if;
  end if;

  select active_season_id into active_season
  from app.app_settings where id = true;
  if active_season is not null then
    perform private.ensure_member_season(new.id, active_season);
  end if;
  return new;
end;
$$;

alter table app.members enable trigger members_phase_b_compatibility;

do $$ begin
  create type app.action_item_severity as enum ('info', 'warning', 'critical');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.action_item_status as enum (
    'open',
    'in_progress',
    'resolved',
    'dismissed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.action_item_visibility as enum ('admin_only', 'operations');
exception when duplicate_object then null; end $$;

create or replace function private.action_context_is_safe(p_context jsonb)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    p_context is not null
    and jsonb_typeof(p_context) = 'object'
    and octet_length(p_context::text) <= 4000
    and not exists(
      select 1
      from jsonb_each(p_context) entry
      where not (
        (
          entry.key in (
            'articleId',
            'variantId',
            'orderItemId',
            'receiptId',
            'runId',
            'batchId',
            'memberSeasonId',
            'packageOrderId',
            'paymentId',
            'templateId',
            'jobId'
          )
          and jsonb_typeof(entry.value) = 'string'
          and entry.value #>> '{}' ~
            '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        )
        or (
          entry.key in (
            'sourceRow',
            'quantity',
            'count',
            'attempt',
            'episode',
            'shortage',
            'available',
            'reserved',
            'requested',
            'waiterCount',
            'queueDepth',
            'templateRevision'
          )
          and jsonb_typeof(entry.value) = 'number'
          and entry.value::text ~ '^(0|[1-9][0-9]{0,9})$'
        )
        or (
          entry.key in ('blocked', 'eligible')
          and jsonb_typeof(entry.value) = 'boolean'
        )
      )
    );
$$;

revoke all on function private.action_context_is_safe(jsonb)
from public, anon, authenticated, service_role;

create table app.action_items (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type ~ '^[a-z][a-z0-9_]{2,63}$'),
  season_id uuid not null references app.seasons(id) on delete restrict,
  object_type text not null check (object_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  object_id uuid not null,
  source_type text not null check (source_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  source_id uuid,
  dedupe_key text not null check (
    dedupe_key ~ '^[0-9a-f]{64}$'
  ),
  episode integer not null default 1 check (episode > 0),
  severity app.action_item_severity not null,
  status app.action_item_status not null default 'open',
  visibility app.action_item_visibility not null default 'operations',
  owner_user_id uuid,
  reason_code text not null check (reason_code ~ '^[a-z][a-z0-9._-]{2,63}$'),
  safe_context jsonb not null default '{}'::jsonb,
  opened_at timestamptz not null default timezone('utc', now()),
  last_seen_at timestamptz not null default timezone('utc', now()),
  due_at timestamptz,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint action_items_context_check check (
    private.action_context_is_safe(safe_context)
  ),
  constraint action_items_resolution_check check (
    (
      status in ('open', 'in_progress')
      and resolved_at is null
      and resolved_by is null
      and resolution_reason is null
    )
    or (
      status in ('resolved', 'dismissed')
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(resolution_reason)) between 3 and 500
    )
  )
);

create unique index action_items_episode_key_idx
  on app.action_items(type, season_id, dedupe_key, episode);
create unique index action_items_one_active_condition_idx
  on app.action_items(type, season_id, dedupe_key)
  where status in ('open', 'in_progress');
create index action_items_operations_queue_idx
  on app.action_items(season_id, status, severity, due_at, opened_at)
  where status in ('open', 'in_progress');

create trigger action_items_touch_updated_at
before update on app.action_items
for each row execute function app.touch_updated_at();

alter table app.action_items enable row level security;
create policy "administrators can read all action items"
on app.action_items
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);
create policy "clothing staff can read operations action items"
on app.action_items
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'kledingcommissie'
  and visibility = 'operations'
);

revoke all on table app.action_items
from public, anon, authenticated, service_role;
grant select on table app.action_items to authenticated;

create or replace function private.open_action_item(
  p_type text,
  p_season_id uuid,
  p_object_type text,
  p_object_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_dedupe_key text,
  p_severity app.action_item_severity,
  p_visibility app.action_item_visibility,
  p_reason_code text,
  p_safe_context jsonb,
  p_due_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result uuid;
  next_episode integer;
  active_item app.action_items%rowtype;
begin
  if p_type is null
    or p_type !~ '^[a-z][a-z0-9_]{2,63}$'
    or p_season_id is null
    or p_object_type is null
    or p_object_type !~ '^[a-z][a-z0-9_]{1,63}$'
    or p_object_id is null
    or p_source_type is null
    or p_source_type !~ '^[a-z][a-z0-9_]{1,63}$'
    or p_dedupe_key is null
    or p_dedupe_key !~ '^[0-9a-f]{64}$'
    or p_severity is null
    or p_visibility is null
    or p_reason_code is null
    or p_reason_code !~ '^[a-z][a-z0-9._-]{2,63}$'
    or p_safe_context is null
    or not private.action_context_is_safe(p_safe_context)
  then
    raise exception 'ACTION_ITEM_INPUT_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'action-item:' || p_type || ':' || p_season_id::text || ':' || p_dedupe_key,
      0
    )
  );

  select * into active_item
  from app.action_items item
  where item.type = p_type
    and item.season_id = p_season_id
    and item.dedupe_key = p_dedupe_key
    and item.status in ('open', 'in_progress')
  for update;

  if found then
    if active_item.object_type <> p_object_type
      or active_item.object_id <> p_object_id
      or active_item.source_type <> p_source_type
      or active_item.visibility <> p_visibility
    then
      raise exception 'ACTION_ITEM_DEDUPE_COLLISION' using errcode = '23505';
    end if;

    update app.action_items
    set last_seen_at = timezone('utc', now()),
        source_id = coalesce(p_source_id, source_id),
        severity = p_severity,
        reason_code = p_reason_code,
        safe_context = p_safe_context,
        due_at = p_due_at
    where id = active_item.id
    returning id into result;
    return result;
  end if;

  select coalesce(max(item.episode), 0) + 1 into next_episode
  from app.action_items item
  where item.type = p_type
    and item.season_id = p_season_id
    and item.dedupe_key = p_dedupe_key;

  insert into app.action_items(
    type,
    season_id,
    object_type,
    object_id,
    source_type,
    source_id,
    dedupe_key,
    episode,
    severity,
    visibility,
    reason_code,
    safe_context,
    due_at
  )
  values(
    p_type,
    p_season_id,
    p_object_type,
    p_object_id,
    p_source_type,
    p_source_id,
    p_dedupe_key,
    next_episode,
    p_severity,
    p_visibility,
    p_reason_code,
    p_safe_context,
    p_due_at
  )
  returning id into result;
  return result;
end;
$$;

revoke all on function private.open_action_item(
  text, uuid, text, uuid, text, uuid, text,
  app.action_item_severity, app.action_item_visibility, text, jsonb, timestamptz
) from public, anon, authenticated, service_role;

create or replace function app.resolve_action_item(
  p_action_item_id uuid,
  p_resolution app.action_item_status,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  role app.staff_role := app.staff_role();
  target app.action_items%rowtype;
begin
  if actor is null
    or coalesce(auth.jwt()->>'aal', '') <> 'aal2'
    or role not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_action_item_id is null
    or p_resolution not in ('resolved', 'dismissed')
    or p_reason is null
    or length(btrim(p_reason)) not between 3 and 500
  then
    raise exception 'ACTION_ITEM_RESOLUTION_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.action_items item
  where item.id = p_action_item_id
  for update;
  if not found then
    raise exception 'ACTION_ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if role = 'kledingcommissie' and target.visibility <> 'operations' then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if target.status in ('resolved', 'dismissed') then
    if target.status = p_resolution and target.resolution_reason = btrim(p_reason) then
      return jsonb_build_object('id', target.id, 'status', target.status::text, 'reused', true);
    end if;
    raise exception 'ACTION_ITEM_ALREADY_CLOSED' using errcode = '40001';
  end if;

  update app.action_items
  set status = p_resolution,
      resolved_at = timezone('utc', now()),
      resolved_by = actor,
      resolution_reason = btrim(p_reason)
  where id = target.id;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(
    actor,
    case
      when p_resolution = 'resolved' then 'action_item.resolved'
      else 'action_item.dismissed'
    end,
    'action_item',
    target.id,
    jsonb_build_object('type', target.type, 'seasonId', target.season_id),
    p_correlation_id
  );
  return jsonb_build_object('id', target.id, 'status', p_resolution::text, 'reused', false);
end;
$$;

revoke all on function app.resolve_action_item(
  uuid, app.action_item_status, text, uuid
) from public, anon;
grant execute on function app.resolve_action_item(
  uuid, app.action_item_status, text, uuid
) to authenticated;

create or replace function app.get_parent_access_workspace(
  p_season_id uuid default null,
  p_search text default null,
  p_offset integer default 0,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_season_id uuid;
  normalized_search text := nullif(lower(trim(p_search)), '');
  result jsonb;
begin
  perform private.require_admin_aal2();
  if p_offset is null or p_offset < 0
    or p_limit is null or p_limit not between 1 and 100
    or length(coalesce(p_search, '')) > 120
  then
    raise exception 'PARENT_ACCESS_QUERY_INVALID' using errcode = '22023';
  end if;

  target_season_id := coalesce(
    p_season_id,
    (select settings.active_season_id from app.app_settings settings where settings.id = true)
  );
  if target_season_id is null
    or not exists(select 1 from app.seasons season where season.id = target_season_id)
  then
    raise exception 'PARENT_ACCESS_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  with visible as (
    select member_season.id member_season_id,
      member.id member_id,
      member.relation_number,
      member.first_name,
      member.insertion,
      member.last_name,
      member.email,
      lower(trim(member.email)) email_normalized,
      member_season.team_name,
      member_season.participation_status,
      member_season.reconciliation_status
    from app.member_seasons member_season
    join app.members member on member.id = member_season.member_id
    where member_season.season_id = target_season_id
      and (
        normalized_search is null
        or lower(concat_ws(' ', member.first_name, member.insertion, member.last_name))
          like '%' || normalized_search || '%'
        or lower(coalesce(member.relation_number, '')) like '%' || normalized_search || '%'
        or lower(coalesce(member.email, '')) like '%' || normalized_search || '%'
        or lower(coalesce(member_season.team_name, '')) like '%' || normalized_search || '%'
      )
  ),
  page as (
    select *
    from visible
    order by lower(last_name), lower(first_name), relation_number nulls last, member_season_id
    offset p_offset
    limit p_limit
  )
  select jsonb_build_object(
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
      from app.seasons season where season.id = target_season_id
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
    'offset', p_offset,
    'limit', p_limit,
    'total', (select count(*) from visible),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberSeasonId', page.member_season_id,
        'memberId', page.member_id,
        'relationNumber', page.relation_number,
        'firstName', page.first_name,
        'insertion', page.insertion,
        'lastName', page.last_name,
        'emailState', case
          when page.email is null or length(trim(page.email)) = 0 then 'missing'
          when private.parent_access_email_valid(page.email) then 'valid'
          else 'invalid'
        end,
        'emailMasked', case
          when private.parent_access_email_valid(page.email) then
            left(page.email_normalized, 1)
              || '***@'
              || split_part(page.email_normalized, '@', 2)
          else null
        end,
        'sharedEmailMemberCount', case
          when private.parent_access_email_valid(page.email) then (
            select count(*)
            from app.member_seasons other_member_season
            join app.members other_member
              on other_member.id = other_member_season.member_id
            where other_member_season.season_id = target_season_id
              and lower(trim(other_member.email)) = page.email_normalized
          )
          else 0
        end,
        'team', page.team_name,
        'participationStatus', page.participation_status::text,
        'reconciliationStatus', page.reconciliation_status::text,
        'emailValid', private.parent_access_email_valid(page.email),
        'grant', (
          select jsonb_build_object(
            'id', grant_row.id,
            'status', grant_row.status::text,
            'source', grant_row.source,
            'grantedAt', grant_row.granted_at,
            'revokedAt', grant_row.revoked_at
          )
          from private.parent_portal_grants grant_row
          where grant_row.member_season_id = page.member_season_id
          order by
            case grant_row.status
              when 'active' then 1
              when 'review_required' then 2
              when 'pending_account' then 3
              else 4
            end,
            grant_row.updated_at desc,
            grant_row.id
          limit 1
        )
      ) order by lower(page.last_name), lower(page.first_name),
        page.relation_number nulls last, page.member_season_id)
      from page
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

notify pgrst, 'reload schema';
