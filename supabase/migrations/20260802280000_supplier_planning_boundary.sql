-- Free-Kick supplier planning is a separate, aggregate-only security
-- principal. It is deliberately not a fourth staff role and receives no
-- grants on member, order, payment or inventory tables.

alter table private.rate_limit_events
  drop constraint rate_limit_events_scope_check;
alter table private.rate_limit_events
  add constraint rate_limit_events_scope_check check (
    scope in (
      'otp_request',
      'otp_verify',
      'mollie_create',
      'export',
      'search',
      'supplier_login'
    )
  );

create or replace function app.consume_rate_limit(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := timezone('utc', now());
begin
  if p_scope is null
    or p_scope <> all(array[
      'otp_request',
      'otp_verify',
      'mollie_create',
      'export',
      'search',
      'supplier_login'
    ])
  then
    raise exception 'INVALID_RATE_LIMIT_SCOPE' using errcode = '22023';
  end if;
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_RATE_LIMIT_KEY' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 1000
    or p_window_seconds is null or p_window_seconds not between 1 and 86400
  then
    raise exception 'INVALID_RATE_LIMIT_BOUNDS' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_scope || ':' || p_key_hash, 0)
  );

  if (
    select count(*)
    from private.rate_limit_events event
    where event.scope = p_scope
      and event.key_hash = p_key_hash
      and event.occurred_at
        > now_utc - make_interval(secs => p_window_seconds)
  ) >= p_limit then
    return false;
  end if;

  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values(p_scope, p_key_hash, now_utc);
  return true;
end;
$$;

revoke all on function app.consume_rate_limit(
  text, text, integer, integer
) from public, anon, authenticated;
grant execute on function app.consume_rate_limit(
  text, text, integer, integer
) to service_role;

create table private.supplier_planner_principals (
  id uuid primary key default gen_random_uuid(),
  display_name text not null check (
    display_name = btrim(display_name)
    and length(display_name) between 2 and 120
  ),
  access_token_hash text not null unique check (
    access_token_hash ~ '^[0-9a-f]{64}$'
  ),
  token_version integer not null default 1 check (token_version > 0),
  active boolean not null default true,
  created_by uuid not null references app.staff_profiles(auth_user_id)
    on delete restrict,
  updated_by uuid not null references app.staff_profiles(auth_user_id)
    on delete restrict,
  disabled_at timestamptz,
  disabled_reason text check (
    disabled_reason is null
    or (
      disabled_reason = btrim(disabled_reason)
      and length(disabled_reason) between 4 and 500
    )
  ),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint supplier_planner_principal_state_check check (
    (active and disabled_at is null and disabled_reason is null)
    or (
      not active
      and disabled_at is not null
      and disabled_reason is not null
    )
  )
);

create table private.supplier_planner_sessions (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  principal_id uuid not null
    references private.supplier_planner_principals(id) on delete restrict,
  token_version integer not null check (token_version > 0),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  constraint supplier_planner_session_expiry_check check (
    expires_at > created_at
  )
);

create table private.supplier_planner_season_grants (
  principal_id uuid not null
    references private.supplier_planner_principals(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  granted_by uuid not null references app.staff_profiles(auth_user_id)
    on delete restrict,
  granted_at timestamptz not null default timezone('utc', now()),
  primary key (principal_id, season_id)
);

create index supplier_planner_sessions_principal_idx
  on private.supplier_planner_sessions(
    principal_id,
    coalesce(revoked_at, expires_at)
  );

create table private.supplier_planner_admin_requests (
  request_id uuid primary key,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  action text not null check (
    action in ('create', 'rotate', 'disable', 'set_seasons')
  ),
  principal_id uuid not null
    references private.supplier_planner_principals(id) on delete restrict,
  response_payload jsonb not null check (
    jsonb_typeof(response_payload) = 'object'
    and not response_payload ?| array[
      'accessToken',
      'accessTokenHash',
      'sessionToken',
      'sessionTokenHash'
    ]
  ),
  created_at timestamptz not null default timezone('utc', now())
);

create index supplier_planner_admin_requests_retention_idx
  on private.supplier_planner_admin_requests(created_at);

create table private.supplier_planner_events (
  id uuid primary key default gen_random_uuid(),
  principal_id uuid
    references private.supplier_planner_principals(id) on delete restrict,
  event_type text not null check (
    event_type in (
      'principal_created',
      'principal_rotated',
      'principal_disabled',
      'principal_seasons_changed',
      'login_succeeded',
      'login_failed',
      'logout_succeeded',
      'planning_viewed'
    )
  ),
  actor_user_id uuid references app.staff_profiles(auth_user_id)
    on delete restrict,
  season_id uuid references app.seasons(id) on delete restrict,
  request_id uuid,
  credential_version integer check (
    credential_version is null or credential_version > 0
  ),
  row_count integer check (row_count is null or row_count >= 0),
  response_hash text check (
    response_hash is null or response_hash ~ '^[0-9a-f]{64}$'
  ),
  correlation_id uuid,
  reason text check (
    reason is null
    or (
      reason = btrim(reason)
      and length(reason) between 4 and 500
    )
  ),
  created_at timestamptz not null default timezone('utc', now()),
  constraint supplier_planner_event_shape_check check (
    (
      event_type in (
        'principal_created',
        'principal_rotated',
        'principal_disabled',
        'principal_seasons_changed'
      )
      and principal_id is not null
      and actor_user_id is not null
      and request_id is not null
      and credential_version is not null
      and season_id is null
      and row_count is null
      and response_hash is null
    )
    or (
      event_type in ('login_succeeded', 'logout_succeeded')
      and principal_id is not null
      and actor_user_id is null
      and request_id is null
      and credential_version is not null
      and season_id is null
      and row_count is null
      and response_hash is null
      and reason is null
    )
    or (
      event_type = 'login_failed'
      and principal_id is null
      and actor_user_id is null
      and request_id is null
      and season_id is null
      and row_count is null
      and credential_version is null
      and response_hash is null
      and correlation_id is null
      and reason is null
    )
    or (
      event_type = 'planning_viewed'
      and principal_id is not null
      and actor_user_id is null
      and request_id is null
      and season_id is not null
      and row_count is not null
      and credential_version is not null
      and response_hash is not null
      and reason is null
    )
  )
);

create index supplier_planner_events_retention_idx
  on private.supplier_planner_events(created_at);
create index supplier_planner_events_principal_idx
  on private.supplier_planner_events(principal_id, created_at desc);

alter table private.supplier_planner_principals enable row level security;
alter table private.supplier_planner_sessions enable row level security;
alter table private.supplier_planner_season_grants enable row level security;
alter table private.supplier_planner_admin_requests enable row level security;
alter table private.supplier_planner_events enable row level security;

revoke all on table private.supplier_planner_principals
  from public, anon, authenticated, service_role;
revoke all on table private.supplier_planner_sessions
  from public, anon, authenticated, service_role;
revoke all on table private.supplier_planner_season_grants
  from public, anon, authenticated, service_role;
revoke all on table private.supplier_planner_admin_requests
  from public, anon, authenticated, service_role;
revoke all on table private.supplier_planner_events
  from public, anon, authenticated, service_role;

create or replace function private.reject_supplier_planner_immutable_mutation()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  if current_setting('app.supplier_planner_retention', true) = 'on'
    and tg_op = 'DELETE'
  then
    return old;
  end if;
  raise exception 'SUPPLIER_PLANNER_HISTORY_IMMUTABLE' using errcode = '42501';
end;
$$;

create trigger supplier_planner_admin_requests_immutable
before update or delete on private.supplier_planner_admin_requests
for each row execute function
  private.reject_supplier_planner_immutable_mutation();
create trigger supplier_planner_events_immutable
before update or delete on private.supplier_planner_events
for each row execute function
  private.reject_supplier_planner_immutable_mutation();

revoke all on function
  private.reject_supplier_planner_immutable_mutation()
from public, anon, authenticated, service_role;

create or replace function app.get_supplier_planner_admin_workspace_v1(
  p_actor_id uuid,
  p_staff_session_hash text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder'::app.staff_role]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'principals',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', principal.id,
          'displayName', principal.display_name,
          'active', principal.active,
          'tokenVersion', principal.token_version,
          'createdAt', principal.created_at,
          'updatedAt', principal.updated_at,
          'disabledAt', principal.disabled_at,
          'seasonIds', coalesce((
            select jsonb_agg(grant_row.season_id order by grant_row.season_id)
            from private.supplier_planner_season_grants grant_row
            where grant_row.principal_id = principal.id
          ), '[]'::jsonb),
          'activeSessions', (
            select count(*)
            from private.supplier_planner_sessions session
            where session.principal_id = principal.id
              and session.revoked_at is null
              and session.expires_at > timezone('utc', now())
              and session.token_version = principal.token_version
          ),
          'lastUsedAt', (
            select max(event.created_at)
            from private.supplier_planner_events event
            where event.principal_id = principal.id
              and event.event_type in (
                'login_succeeded',
                'planning_viewed'
              )
          )
        )
        order by principal.active desc, principal.display_name, principal.id
      )
      from private.supplier_planner_principals principal
    ), '[]'::jsonb),
    'seasons',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', season.id,
          'name', season.name,
          'status', season.status::text
        )
        order by season.starts_on desc nulls last, season.name, season.id
      )
      from app.seasons season
      where season.status = 'open'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.manage_supplier_planner_v1(
  p_action text,
  p_actor_id uuid,
  p_staff_session_hash text,
  p_request_id uuid,
  p_principal_id uuid default null,
  p_display_name text default null,
  p_access_token_hash text default null,
  p_reason text default null,
  p_season_ids uuid[] default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  normalized_name text := regexp_replace(
    btrim(coalesce(p_display_name, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  normalized_reason text := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  request_hash text;
  existing private.supplier_planner_admin_requests%rowtype;
  principal private.supplier_planner_principals%rowtype;
  response jsonb;
  event_type text;
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder'::app.staff_role]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_request_id is null
    or p_action is null
    or p_action not in ('create', 'rotate', 'disable', 'set_seasons')
  then
    raise exception 'SUPPLIER_PLANNER_REQUEST_INVALID' using errcode = '22023';
  end if;

  if p_action = 'create' then
    if p_principal_id is not null
      or length(normalized_name) not between 2 and 120
      or p_access_token_hash is null
      or p_access_token_hash !~ '^[0-9a-f]{64}$'
      or normalized_reason <> ''
      or coalesce(array_length(p_season_ids, 1), 0) < 1
    then
      raise exception 'SUPPLIER_PLANNER_REQUEST_INVALID' using errcode = '22023';
    end if;
  elsif p_action = 'rotate' then
    if p_principal_id is null
      or normalized_name <> ''
      or p_access_token_hash is null
      or p_access_token_hash !~ '^[0-9a-f]{64}$'
      or length(normalized_reason) not between 4 and 500
      or p_season_ids is not null
    then
      raise exception 'SUPPLIER_PLANNER_REQUEST_INVALID' using errcode = '22023';
    end if;
  elsif p_action = 'disable' and (
    p_principal_id is null
    or normalized_name <> ''
    or p_access_token_hash is not null
    or length(normalized_reason) not between 4 and 500
    or p_season_ids is not null
  ) then
    raise exception 'SUPPLIER_PLANNER_REQUEST_INVALID' using errcode = '22023';
  elsif p_action = 'set_seasons' and (
    p_principal_id is null
    or normalized_name <> ''
    or p_access_token_hash is not null
    or length(normalized_reason) not between 4 and 500
    or coalesce(array_length(p_season_ids, 1), 0) < 1
  ) then
    raise exception 'SUPPLIER_PLANNER_REQUEST_INVALID' using errcode = '22023';
  end if;

  if p_season_ids is not null and (
    (
      select count(distinct season_id)
      from unnest(p_season_ids) season_id
    ) <> array_length(p_season_ids, 1)
    or (
      select count(*)
      from app.seasons season
      where season.id = any(p_season_ids)
        and season.status = 'open'
    ) <> array_length(p_season_ids, 1)
  ) then
    raise exception 'SUPPLIER_PLANNER_SEASONS_INVALID' using errcode = '22023';
  end if;

  request_hash := encode(
    digest(
      convert_to(
        concat_ws(
          ':',
          p_action,
          coalesce(p_principal_id::text, ''),
          normalized_name,
          coalesce(p_access_token_hash, ''),
          normalized_reason,
          coalesce((
            select string_agg(season_id::text, ',' order by season_id)
            from unnest(p_season_ids) season_id
          ), '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('supplier-planner:' || p_request_id::text, 0)
  );

  select * into existing
  from private.supplier_planner_admin_requests request
  where request.request_id = p_request_id;
  if existing.request_id is not null then
    if existing.request_hash <> request_hash then
      raise exception 'SUPPLIER_PLANNER_REQUEST_CONFLICT' using errcode = '23505';
    end if;
    return existing.response_payload
      || jsonb_build_object('alreadyProcessed', true);
  end if;

  if p_action = 'create' then
    insert into private.supplier_planner_principals(
      display_name,
      access_token_hash,
      created_by,
      updated_by
    ) values (
      normalized_name,
      p_access_token_hash,
      p_actor_id,
      p_actor_id
    )
    returning * into principal;
    insert into private.supplier_planner_season_grants(
      principal_id,
      season_id,
      granted_by
    )
    select principal.id, season_id, p_actor_id
    from unnest(p_season_ids) season_id;
    event_type := 'principal_created';
  else
    select * into principal
    from private.supplier_planner_principals item
    where item.id = p_principal_id
    for update;
    if principal.id is null then
      raise exception 'SUPPLIER_PLANNER_NOT_FOUND' using errcode = 'P0002';
    end if;

    if p_action = 'rotate' then
      update private.supplier_planner_principals
      set access_token_hash = p_access_token_hash,
          token_version = token_version + 1,
          active = true,
          disabled_at = null,
          disabled_reason = null,
          updated_by = p_actor_id,
          updated_at = timezone('utc', now())
      where id = principal.id
      returning * into principal;
      event_type := 'principal_rotated';
    elsif p_action = 'disable' then
      update private.supplier_planner_principals
      set active = false,
          disabled_at = timezone('utc', now()),
          disabled_reason = normalized_reason,
          updated_by = p_actor_id,
          updated_at = timezone('utc', now())
      where id = principal.id
      returning * into principal;
      event_type := 'principal_disabled';
    else
      delete from private.supplier_planner_season_grants grant_row
      where grant_row.principal_id = principal.id;
      insert into private.supplier_planner_season_grants(
        principal_id,
        season_id,
        granted_by
      )
      select principal.id, season_id, p_actor_id
      from unnest(p_season_ids) season_id;
      update private.supplier_planner_principals
      set updated_by = p_actor_id,
          updated_at = timezone('utc', now())
      where id = principal.id
      returning * into principal;
      event_type := 'principal_seasons_changed';
    end if;

    if p_action in ('rotate', 'disable', 'set_seasons') then
      update private.supplier_planner_sessions
      set revoked_at = timezone('utc', now())
      where principal_id = principal.id
        and revoked_at is null;
    end if;
  end if;

  response := jsonb_build_object(
    'principal',
    jsonb_build_object(
      'id', principal.id,
      'displayName', principal.display_name,
      'active', principal.active,
      'tokenVersion', principal.token_version,
      'createdAt', principal.created_at,
      'updatedAt', principal.updated_at,
      'disabledAt', principal.disabled_at,
      'seasonIds', coalesce((
        select jsonb_agg(grant_row.season_id order by grant_row.season_id)
        from private.supplier_planner_season_grants grant_row
        where grant_row.principal_id = principal.id
      ), '[]'::jsonb),
      'activeSessions', 0,
      'lastUsedAt', null
    ),
    'action', p_action,
    'alreadyProcessed', false
  );

  insert into private.supplier_planner_admin_requests(
    request_id,
    request_hash,
    action,
    principal_id,
    response_payload
  ) values (
    p_request_id,
    request_hash,
    p_action,
    principal.id,
    response
  );
  insert into private.supplier_planner_events(
    principal_id,
    event_type,
    actor_user_id,
    request_id,
    credential_version,
    reason
  ) values (
    principal.id,
    event_type,
    p_actor_id,
    p_request_id,
    principal.token_version,
    nullif(normalized_reason, '')
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    p_actor_id,
    'supplier_planner.' || p_action,
    'supplier_planner',
    principal.id,
    jsonb_build_object(
      'requestId', p_request_id,
      'reason', nullif(normalized_reason, ''),
      'active', principal.active,
      'tokenVersion', principal.token_version,
      'seasonIds', coalesce((
        select jsonb_agg(grant_row.season_id order by grant_row.season_id)
        from private.supplier_planner_season_grants grant_row
        where grant_row.principal_id = principal.id
      ), '[]'::jsonb)
    )
  );
  return response;
exception
  when unique_violation then
    if exists(
      select 1
      from private.supplier_planner_principals item
      where item.access_token_hash = p_access_token_hash
    ) then
      raise exception 'SUPPLIER_PLANNER_TOKEN_CONFLICT' using errcode = '23505';
    end if;
    raise;
end;
$$;

create or replace function app.create_supplier_planner_session_v1(
  p_access_token_hash text,
  p_session_token_hash text,
  p_ip_key_hash text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  principal private.supplier_planner_principals%rowtype;
  now_utc timestamptz := timezone('utc', now());
begin
  if p_access_token_hash is null
    or p_access_token_hash !~ '^[0-9a-f]{64}$'
    or p_session_token_hash is null
    or p_session_token_hash !~ '^[0-9a-f]{64}$'
    or p_ip_key_hash is null
    or p_ip_key_hash !~ '^[0-9a-f]{64}$'
  then
    return null;
  end if;
  if not app.consume_rate_limit(
    'supplier_login',
    p_ip_key_hash,
    10,
    900
  ) or not app.consume_rate_limit(
    'supplier_login',
    encode(
      extensions.digest(
        convert_to('supplier-login-global-v1', 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    500,
    900
  ) then
    return null;
  end if;

  select * into principal
  from private.supplier_planner_principals item
  where item.access_token_hash = p_access_token_hash
    and item.active
  for update;
  if principal.id is null then
    insert into private.supplier_planner_events(
      principal_id,
      event_type
    ) values (
      null,
      'login_failed'
    );
    return null;
  end if;

  insert into private.supplier_planner_sessions(
    token_hash,
    principal_id,
    token_version,
    expires_at
  ) values (
    p_session_token_hash,
    principal.id,
    principal.token_version,
    now_utc + interval '8 hours'
  );
  insert into private.supplier_planner_events(
    principal_id,
    event_type,
    credential_version
  ) values (
    principal.id,
    'login_succeeded',
    principal.token_version
  );

  return jsonb_build_object(
    'principalId', principal.id,
    'displayName', principal.display_name,
    'expiresAt', now_utc + interval '8 hours'
  );
exception when unique_violation then
  return null;
end;
$$;

create or replace function app.get_supplier_planner_context_v1(
  p_session_token_hash text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  principal private.supplier_planner_principals%rowtype;
begin
  if p_session_token_hash is null
    or p_session_token_hash !~ '^[0-9a-f]{64}$'
  then
    return null;
  end if;

  select item.* into principal
  from private.supplier_planner_sessions session
  join private.supplier_planner_principals item
    on item.id = session.principal_id
  where session.token_hash = p_session_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
    and session.token_version = item.token_version
    and item.active;
  if principal.id is null then return null; end if;

  return jsonb_build_object(
    'principalId', principal.id,
    'displayName', principal.display_name,
    'activeSeason', (
      select jsonb_build_object('id', season.id, 'name', season.name)
      from app.app_settings settings
      join app.seasons season
        on season.id = settings.active_season_id
        and season.status = 'open'
      join private.supplier_planner_season_grants grant_row
        on grant_row.principal_id = principal.id
        and grant_row.season_id = season.id
      where settings.id = true
      limit 1
    ),
    'seasons', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', season.id, 'name', season.name)
        order by season.starts_on desc nulls last, season.name, season.id
      )
      from app.seasons season
      join private.supplier_planner_season_grants grant_row
        on grant_row.season_id = season.id
        and grant_row.principal_id = principal.id
      where season.status = 'open'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.revoke_supplier_planner_session_v1(
  p_session_token_hash text
)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  affected integer;
  target_principal_id uuid;
begin
  if p_session_token_hash is null
    or p_session_token_hash !~ '^[0-9a-f]{64}$'
  then
    return 0;
  end if;

  update private.supplier_planner_sessions
  set revoked_at = timezone('utc', now())
  where token_hash = p_session_token_hash
    and revoked_at is null
  returning principal_id into target_principal_id;
  get diagnostics affected = row_count;
  if affected > 0 then
    insert into private.supplier_planner_events(
      principal_id,
      event_type,
      credential_version
    ) values (
      target_principal_id,
      'logout_succeeded',
      (
        select principal.token_version
        from private.supplier_planner_principals principal
        where principal.id = target_principal_id
      )
    );
  end if;
  return affected;
end;
$$;

create or replace function app.get_supplier_planning_v1(
  p_session_token_hash text,
  p_season_id uuid default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  principal private.supplier_planner_principals%rowtype;
  target_season_id uuid := p_season_id;
  result jsonb;
  result_rows integer;
begin
  if p_session_token_hash is null
    or p_session_token_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception 'SUPPLIER_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select item.* into principal
  from private.supplier_planner_sessions session
  join private.supplier_planner_principals item
    on item.id = session.principal_id
  where session.token_hash = p_session_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
    and session.token_version = item.token_version
    and item.active;
  if principal.id is null then
    raise exception 'SUPPLIER_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  if target_season_id is null then
    select settings.active_season_id into target_season_id
    from app.app_settings settings
    where settings.id = true;
  end if;
  if target_season_id is null
    or not exists(
      select 1
      from app.seasons season
      join private.supplier_planner_season_grants grant_row
        on grant_row.season_id = season.id
        and grant_row.principal_id = principal.id
      where season.id = target_season_id
        and season.status = 'open'
    )
  then
    raise exception 'SUPPLIER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'season',
    jsonb_build_object('id', season.id, 'name', season.name),
    'generatedAt',
    timezone('utc', now()),
    'lowStockThreshold',
    coalesce(settings.low_stock_threshold, 10),
    'inventory',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'productName', article.name,
          'productCode', article.code,
          'size', variant.size,
          'supplierCode', variant.sku,
          'productActive', article.active,
          'variantActive', variant.active,
          'physical', balance.on_hand,
          'reserved', balance.reserved,
          'issued', balance.issued,
          'free', balance.available,
          'totalOpenDemand', demand.total_open,
          'shortage', greatest(demand.total_open - balance.on_hand, 0)
        )
        order by
          article.sort_order,
          article.name,
          variant.sort_order,
          variant.size,
          variant.id
      )
      from app.article_seasons link
      join app.articles article
        on article.id = link.article_id
      join app.article_variants variant
        on variant.article_id = article.id
      join lateral private.inventory_balance(
        target_season_id,
        variant.id
      ) balance on true
      left join lateral (
        select
          coalesce(sum(line.quantity) filter (
            where line.status in ('backorder', 'ready_for_pickup')
          ), 0)::bigint total_open,
          count(*)::bigint line_count
        from app.order_lines line
        join app.member_orders orders on orders.id = line.order_id
        where orders.season_id = target_season_id
          and line.article_variant_id = variant.id
      ) demand on true
      where link.season_id = target_season_id
        and (
          article.active
          or variant.active
          or balance.on_hand <> 0
          or balance.reserved <> 0
          or balance.issued <> 0
          or demand.line_count > 0
        )
    ), '[]'::jsonb),
    'demandByGender',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'productName', demand.product_name,
          'productCode', demand.product_code,
          'size', demand.size,
          'supplierCode', demand.supplier_code,
          'gender', demand.gender,
          'totalOpenDemand', demand.total_open,
          'paidWaiting', demand.paid_waiting,
          'unpaidDemand', demand.unpaid,
          'unconfirmedDemand', demand.unconfirmed,
          'pickedUp', demand.picked_up
        )
        order by
          demand.article_sort,
          demand.product_name,
          demand.variant_sort,
          demand.size,
          demand.gender
      )
      from (
        select
          article.sort_order article_sort,
          article.name product_name,
          article.code product_code,
          variant.sort_order variant_sort,
          variant.size,
          variant.sku supplier_code,
          member.gender::text gender,
          coalesce(sum(line.quantity) filter (
            where line.status in ('backorder', 'ready_for_pickup')
          ), 0)::bigint total_open,
          coalesce(sum(line.quantity) filter (
            where line.status = 'backorder'
              and paid.is_paid
              and size_state.is_valid
          ), 0)::bigint paid_waiting,
          coalesce(sum(line.quantity) filter (
            where line.status = 'backorder'
              and not paid.is_paid
          ), 0)::bigint unpaid,
          coalesce(sum(line.quantity) filter (
            where line.status = 'backorder'
              and not size_state.is_valid
          ), 0)::bigint unconfirmed,
          coalesce(sum(line.quantity) filter (
            where line.status = 'picked_up'
          ), 0)::bigint picked_up
        from app.order_lines line
        join app.member_orders orders on orders.id = line.order_id
        join app.members member on member.id = orders.member_id
        join app.articles article on article.id = line.article_id
        join app.article_variants variant
          on variant.id = line.article_variant_id
        left join lateral (
          select exists(
            select 1
            from app.payments payment
            where payment.order_id = orders.id
              and payment.status = 'paid'
              and payment.reconciliation_issue is null
          ) is_paid
        ) paid on true
        left join lateral (
          select exists(
            select 1
            from app.member_article_sizes size_profile
            where size_profile.member_season_id = orders.member_season_id
              and size_profile.article_id = line.article_id
              and size_profile.article_variant_id = line.article_variant_id
              and size_profile.selection_status in ('confirmed', 'locked')
              and size_profile.confirmed_at is not null
          ) is_valid
        ) size_state on true
        where orders.season_id = target_season_id
        group by
          article.id,
          article.sort_order,
          article.name,
          article.code,
          variant.id,
          variant.sort_order,
          variant.size,
          variant.sku,
          member.gender
      ) demand
      where demand.total_open > 0 or demand.picked_up > 0
    ), '[]'::jsonb),
    'unresolvedSizeDemand',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'productName', unresolved.product_name,
          'productCode', unresolved.product_code,
          'gender', unresolved.gender,
          'totalDemand', unresolved.total_demand,
          'paidDemand', unresolved.paid_demand,
          'unpaidDemand', unresolved.unpaid_demand,
          'missing', unresolved.missing,
          'unconfirmed', unresolved.unconfirmed,
          'conflict', unresolved.conflict
        )
        order by
          unresolved.article_sort,
          unresolved.product_name,
          unresolved.gender
      )
      from (
        select
          article.sort_order article_sort,
          article.name product_name,
          article.code product_code,
          member.gender::text gender,
          sum(snapshot_item.quantity)::bigint total_demand,
          coalesce(sum(snapshot_item.quantity) filter (
            where paid.is_paid
          ), 0)::bigint paid_demand,
          coalesce(sum(snapshot_item.quantity) filter (
            where not paid.is_paid
          ), 0)::bigint unpaid_demand,
          coalesce(sum(snapshot_item.quantity) filter (
            where size_profile.member_id is null
          ), 0)::bigint missing,
          coalesce(sum(snapshot_item.quantity) filter (
            where size_profile.selection_status = 'imported_unconfirmed'
          ), 0)::bigint unconfirmed,
          coalesce(sum(snapshot_item.quantity) filter (
            where size_profile.selection_status = 'conflict'
          ), 0)::bigint conflict
        from app.member_orders orders
        join app.members member on member.id = orders.member_id
        join app.order_package_snapshots snapshot
          on snapshot.id = orders.active_package_snapshot_id
        join app.order_package_snapshot_items snapshot_item
          on snapshot_item.snapshot_id = snapshot.id
        join app.articles article on article.id = snapshot_item.article_id
        left join app.member_article_sizes size_profile
          on size_profile.member_season_id = orders.member_season_id
          and size_profile.article_id = snapshot_item.article_id
        left join lateral (
          select exists(
            select 1
            from app.payments payment
            where payment.order_id = orders.id
              and payment.status = 'paid'
              and payment.reconciliation_issue is null
          ) is_paid
        ) paid on true
        where orders.season_id = target_season_id
          and (
            size_profile.member_id is null
            or size_profile.selection_status in (
              'imported_unconfirmed',
              'conflict'
            )
          )
        group by
          article.id,
          article.sort_order,
          article.name,
          article.code,
          member.gender
      ) unresolved
    ), '[]'::jsonb)
  )
  into result
  from app.seasons season
  left join app.inventory_settings settings
    on settings.season_id = season.id
  where season.id = target_season_id;

  result_rows := jsonb_array_length(result->'inventory')
    + jsonb_array_length(result->'demandByGender')
    + jsonb_array_length(result->'unresolvedSizeDemand');
  insert into private.supplier_planner_events(
    principal_id,
    event_type,
    season_id,
    credential_version,
    row_count,
    response_hash,
    correlation_id
  ) values (
    principal.id,
    'planning_viewed',
    target_season_id,
    principal.token_version,
    result_rows,
    encode(
      extensions.digest(convert_to(result::text, 'UTF8'), 'sha256'),
      'hex'
    ),
    p_correlation_id
  );
  return result;
end;
$$;

create or replace function app.purge_supplier_planner_history_v1(
  p_now timestamptz,
  p_session_retention_days integer default 30,
  p_event_retention_days integer default 365,
  p_limit integer default 500
)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  session_count integer;
  request_count integer;
  event_count integer;
begin
  if p_now is null
    or p_session_retention_days not between 7 and 90
    or p_event_retention_days not between 90 and 730
    or p_limit not between 1 and 5000
  then
    raise exception 'SUPPLIER_RETENTION_INVALID' using errcode = '22023';
  end if;

  update private.supplier_planner_sessions
  set revoked_at = p_now
  where revoked_at is null
    and expires_at <= p_now;

  with removed as (
    delete from private.supplier_planner_sessions session
    where session.token_hash in (
      select candidate.token_hash
      from private.supplier_planner_sessions candidate
      where coalesce(candidate.revoked_at, candidate.expires_at)
        <= p_now - make_interval(days => p_session_retention_days)
      order by coalesce(candidate.revoked_at, candidate.expires_at)
      limit p_limit
    )
    returning 1
  )
  select count(*)::integer into session_count from removed;

  perform set_config('app.supplier_planner_retention', 'on', true);
  with removed as (
    delete from private.supplier_planner_admin_requests request
    where request.request_id in (
      select candidate.request_id
      from private.supplier_planner_admin_requests candidate
      where candidate.created_at
        <= p_now - make_interval(days => p_event_retention_days)
      order by candidate.created_at
      limit p_limit
    )
    returning 1
  )
  select count(*)::integer into request_count from removed;
  with removed as (
    delete from private.supplier_planner_events event
    where event.id in (
      select candidate.id
      from private.supplier_planner_events candidate
      where candidate.created_at
        <= p_now - make_interval(days => p_event_retention_days)
      order by candidate.created_at
      limit p_limit
    )
    returning 1
  )
  select count(*)::integer into event_count from removed;
  perform set_config('app.supplier_planner_retention', 'off', true);

  return session_count + request_count + event_count;
end;
$$;

create or replace function app.get_operational_health_v10(
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
  base jsonb := app.get_operational_health_v9(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
begin
  return base || jsonb_build_object(
    'supplierPlanning',
    jsonb_build_object(
      'activePrincipals',
      (
        select count(*)
        from private.supplier_planner_principals principal
        where principal.active
      ),
      'activePrincipalsWithoutOpenSeason',
      (
        select count(*)
        from private.supplier_planner_principals principal
        where principal.active
          and not exists(
            select 1
            from private.supplier_planner_season_grants grant_row
            join app.seasons season
              on season.id = grant_row.season_id
              and season.status = 'open'
            where grant_row.principal_id = principal.id
          )
      ),
      'activeSessions',
      (
        select count(*)
        from private.supplier_planner_sessions session
        join private.supplier_planner_principals principal
          on principal.id = session.principal_id
        where session.revoked_at is null
          and session.expires_at > statement_timestamp()
          and session.token_version = principal.token_version
          and principal.active
      ),
      'unauthorizedActiveSessions',
      (
        select count(*)
        from private.supplier_planner_sessions session
        join private.supplier_planner_principals principal
          on principal.id = session.principal_id
        where session.revoked_at is null
          and session.expires_at > statement_timestamp()
          and (
            not principal.active
            or session.token_version <> principal.token_version
          )
      ),
      'expiredUnrevokedSessions',
      (
        select count(*)
        from private.supplier_planner_sessions session
        where session.revoked_at is null
          and session.expires_at
            <= statement_timestamp() - interval '26 hours'
      ),
      'recentLoginFailures',
      (
        select count(*)
        from private.supplier_planner_events event
        where event.event_type = 'login_failed'
          and event.created_at
            >= statement_timestamp() - interval '15 minutes'
      ),
      'staleCredentials',
      (
        select count(*)
        from private.supplier_planner_principals principal
        where principal.active
          and principal.updated_at
            < statement_timestamp() - interval '365 days'
      ),
      'lastSuccessfulPlanningAt',
      (
        select max(event.created_at)
        from private.supplier_planner_events event
        where event.event_type = 'planning_viewed'
      )
    )
  );
end;
$$;

revoke all on function app.get_supplier_planner_admin_workspace_v1(
  uuid, text
) from public, anon, authenticated, service_role;
revoke all on function app.manage_supplier_planner_v1(
  text, uuid, text, uuid, uuid, text, text, text, uuid[]
) from public, anon, authenticated, service_role;
revoke all on function app.create_supplier_planner_session_v1(
  text, text, text
) from public, anon, authenticated, service_role;
revoke all on function app.get_supplier_planner_context_v1(
  text
) from public, anon, authenticated, service_role;
revoke all on function app.revoke_supplier_planner_session_v1(
  text
) from public, anon, authenticated, service_role;
revoke all on function app.get_supplier_planning_v1(
  text, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function app.purge_supplier_planner_history_v1(
  timestamptz, integer, integer, integer
) from public, anon, authenticated, service_role;
revoke all on function app.get_operational_health_v10(
  text, integer, text, integer
) from public, anon, authenticated, service_role;

grant execute on function app.get_supplier_planner_admin_workspace_v1(
  uuid, text
) to service_role;
grant execute on function app.manage_supplier_planner_v1(
  text, uuid, text, uuid, uuid, text, text, text, uuid[]
) to service_role;
grant execute on function app.create_supplier_planner_session_v1(
  text, text, text
) to service_role;
grant execute on function app.get_supplier_planner_context_v1(
  text
) to service_role;
grant execute on function app.revoke_supplier_planner_session_v1(
  text
) to service_role;
grant execute on function app.get_supplier_planning_v1(
  text, uuid, uuid
) to service_role;
grant execute on function app.purge_supplier_planner_history_v1(
  timestamptz, integer, integer, integer
) to service_role;
grant execute on function app.get_operational_health_v10(
  text, integer, text, integer
) to service_role;

do $$
declare
  direct_private_grants integer;
  staff_role_count integer;
  exposed_functions integer;
begin
  select count(*)::integer into direct_private_grants
  from information_schema.role_table_grants grant_row
  where grant_row.table_schema = 'private'
    and grant_row.table_name in (
      'supplier_planner_principals',
      'supplier_planner_sessions',
      'supplier_planner_season_grants',
      'supplier_planner_admin_requests',
      'supplier_planner_events'
    )
    and grant_row.grantee in ('anon', 'authenticated', 'service_role');

  select count(*)::integer into staff_role_count
  from pg_enum enum_value
  join pg_type enum_type on enum_type.oid = enum_value.enumtypid
  join pg_namespace namespace on namespace.oid = enum_type.typnamespace
  where namespace.nspname = 'app'
    and enum_type.typname = 'staff_role';

  select count(*)::integer into exposed_functions
  from information_schema.routine_privileges privilege
  where privilege.specific_schema = 'app'
    and privilege.routine_name like '%supplier_planner%'
    and privilege.grantee in ('anon', 'authenticated');

  if direct_private_grants <> 0
    or staff_role_count <> 3
    or exposed_functions <> 0
  then
    raise exception 'SUPPLIER_PLANNING_RECONCILIATION_FAILED'
      using errcode = '23514';
  end if;

  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260802280000_supplier_planning_boundary',
    'passed',
    jsonb_build_object(
      'principals', 0,
      'directApiTableGrants', direct_private_grants,
      'staffRoles', staff_role_count,
      'browserCallableFunctions', exposed_functions
    )
  )
  on conflict (migration_key) do update
  set status = excluded.status,
      metrics = excluded.metrics,
      reconciled_at = statement_timestamp();
end;
$$;

comment on function app.get_supplier_planning_v1(text, uuid, uuid) is
  'Returns only product-by-size-and-gender planning aggregates for an explicitly granted season; never member, order, team, DOB, e-mail or individual payment data.';
comment on table private.supplier_planner_principals is
  'Separate aggregate-only supplier principals; deliberately not app.staff_role.';

notify pgrst, 'reload schema';
