-- Administrator-managed, season-bound parent portal access.
--
-- Legacy parent/member links remain as a compatibility projection. They never
-- authorize access by themselves: every read, OTP and payment path below
-- requires an explicit active parent_portal_grant for the exact member-season.

create unique index parent_portal_grants_one_active_member_season_idx
  on private.parent_portal_grants(member_season_id)
  where status = 'active';

create table private.parent_access_batches (
  id uuid primary key default gen_random_uuid(),
  batch_key uuid not null unique,
  operation text not null check (operation in ('activate', 'revoke')),
  season_id uuid not null references app.seasons(id) on delete restrict,
  selection_hash text not null check (selection_hash ~ '^[0-9a-f]{64}$'),
  selected_count integer not null check (selected_count between 1 and 500),
  actor_user_id uuid not null references app.staff_profiles(auth_user_id) on delete restrict,
  result jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  completed_at timestamptz,
  constraint parent_access_batches_completion_check check (
    (result is null and completed_at is null)
    or (result is not null and completed_at is not null)
  )
);

create table private.parent_access_batch_items (
  batch_id uuid not null references private.parent_access_batches(id) on delete restrict,
  member_season_id uuid not null references app.member_seasons(id) on delete restrict,
  grant_id uuid references private.parent_portal_grants(id) on delete restrict,
  outcome text not null check (outcome in ('activated', 'unchanged', 'revoked')),
  primary key (batch_id, member_season_id)
);

create index parent_access_batches_season_created_idx
  on private.parent_access_batches(season_id, created_at desc);
create index parent_access_batch_items_grant_idx
  on private.parent_access_batch_items(grant_id)
  where grant_id is not null;

alter table private.parent_access_batches enable row level security;
alter table private.parent_access_batch_items enable row level security;
revoke all on table private.parent_access_batches
  from public, anon, authenticated, service_role;
revoke all on table private.parent_access_batch_items
  from public, anon, authenticated, service_role;

-- An active administrator grant may not be silently downgraded by the legacy
-- projection trigger. Re-activating a revoked legacy link still requires review.
create or replace function app.sync_legacy_parent_grant()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_season uuid;
  account_email text;
  active_season uuid;
begin
  if current_setting('app.parent_access_internal', true) = 'on' then
    return new;
  end if;
  if new.unlinked_at is not null then
    update private.parent_portal_grants
    set status = 'revoked',
        revoked_at = coalesce(revoked_at, timezone('utc', now())),
        revoked_reason = coalesce(revoked_reason, 'Legacykoppeling ingetrokken'),
        updated_at = timezone('utc', now())
    where legacy_link_id = new.id and status <> 'revoked';
    return new;
  end if;

  select settings.active_season_id into active_season
  from app.app_settings settings where settings.id = true;
  if active_season is null then return new; end if;

  select member_season.id into target_member_season
  from app.member_seasons member_season
  where member_season.member_id = new.member_id
    and member_season.season_id = active_season;
  select account.email_normalized into account_email
  from private.parent_accounts account
  where account.id = new.parent_account_id;
  if target_member_season is null or account_email is null then return new; end if;

  -- A legacy link is member-wide, while a grant is season-bound. Keep the
  -- original compatibility association on at most one grant; later seasons
  -- are created explicitly by the administrator without reusing this unique
  -- link identifier.
  if exists(
    select 1
    from private.parent_portal_grants grant_row
    where grant_row.legacy_link_id = new.id
  ) then
    return new;
  end if;

  insert into private.parent_portal_grants(
    member_season_id,
    email_normalized,
    parent_account_id,
    status,
    source,
    legacy_link_id
  )
  values(
    target_member_season,
    account_email,
    new.parent_account_id,
    'review_required',
    'legacy_review',
    new.id
  )
  on conflict (legacy_link_id) do update
  set email_normalized = case
        when private.parent_portal_grants.status = 'active'
          then private.parent_portal_grants.email_normalized
        else excluded.email_normalized
      end,
      parent_account_id = case
        when private.parent_portal_grants.status = 'active'
          then private.parent_portal_grants.parent_account_id
        else excluded.parent_account_id
      end,
      status = case
        when private.parent_portal_grants.status = 'active'
          then private.parent_portal_grants.status
        else 'review_required'::app.parent_grant_status
      end,
      source = case
        when private.parent_portal_grants.status = 'active'
          then private.parent_portal_grants.source
        else 'legacy_review'
      end,
      granted_by = case
        when private.parent_portal_grants.status = 'active'
          then private.parent_portal_grants.granted_by
        else null
      end,
      granted_at = case
        when private.parent_portal_grants.status = 'active'
          then private.parent_portal_grants.granted_at
        else null
      end,
      revoked_by = null,
      revoked_at = null,
      revoked_reason = null,
      updated_at = timezone('utc', now());
  return new;
end;
$$;

revoke all on function app.sync_legacy_parent_grant()
  from public, anon, authenticated, service_role;

create or replace function private.parent_activation_revision(
  p_season_id uuid,
  p_member_season_ids uuid[]
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(coalesce((
    select jsonb_agg(jsonb_build_object(
      'memberSeasonId', selected.member_season_id,
      'seasonId', member_season.season_id,
      'participation', member_season.participation_status,
      'reconciliation', member_season.reconciliation_status,
      'email', lower(trim(member.email)),
      'openGrants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', grant_row.id,
          'email', grant_row.email_normalized,
          'accountId', grant_row.parent_account_id,
          'status', grant_row.status,
          'legacyLinkId', grant_row.legacy_link_id,
          'updatedAt', grant_row.updated_at
        ) order by grant_row.id)
        from private.parent_portal_grants grant_row
        where grant_row.member_season_id = selected.member_season_id
          and grant_row.status in ('pending_account', 'review_required', 'active')
      ), '[]'::jsonb)
    ) order by selected.member_season_id)
    from unnest(p_member_season_ids) selected(member_season_id)
    left join app.member_seasons member_season
      on member_season.id = selected.member_season_id
    left join app.members member on member.id = member_season.member_id
  ), '[]'::jsonb)::text
    || ':' || coalesce(p_season_id::text, '')
    || ':' || coalesce((
      select jsonb_build_object(
        'templateId', template.id,
        'version', template.version,
        'updatedAt', template.updated_at,
        'clubName', settings.club_name,
        'contactEmail', settings.contact_email
      )::text
      from app.email_templates template
      cross join app.app_settings settings
      where settings.id = true
        and template.template_key = 'portal_access_invite'
        and template.active
    ), 'missing'), 'sha256'), 'hex');
$$;

create or replace function private.parent_revocation_revision(
  p_season_id uuid,
  p_grant_ids uuid[]
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(coalesce((
    select jsonb_agg(jsonb_build_object(
      'grantId', selected.grant_id,
      'memberSeasonId', grant_row.member_season_id,
      'seasonId', member_season.season_id,
      'accountId', grant_row.parent_account_id,
      'status', grant_row.status,
      'updatedAt', grant_row.updated_at
    ) order by selected.grant_id)
    from unnest(p_grant_ids) selected(grant_id)
    left join private.parent_portal_grants grant_row
      on grant_row.id = selected.grant_id
    left join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
  ), '[]'::jsonb)::text || ':' || coalesce(p_season_id::text, ''), 'sha256'), 'hex');
$$;

revoke all on function private.parent_activation_revision(uuid, uuid[])
  from public, anon, authenticated, service_role;
revoke all on function private.parent_revocation_revision(uuid, uuid[])
  from public, anon, authenticated, service_role;

create or replace function private.parent_access_email_valid(p_email text)
returns boolean
language sql
immutable
set search_path = pg_temp
as $$
  select p_email is not null
    and length(lower(trim(p_email))) between 3 and 254
    and lower(trim(p_email)) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$';
$$;

revoke all on function private.parent_access_email_valid(text)
  from public, anon, authenticated, service_role;

create or replace function private.parent_access_v2_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce((
    select flag.enabled
    from app.release_feature_flags flag
    where flag.key = 'parent_access_grants_v2'
  ), false);
$$;

-- During the compatibility window, authorization is still limited to the
-- configured active season, but it is no longer inferred from an address or a
-- member-wide link alone. An explicit active grant wins; an unreconciled
-- legacy link remains usable only through its exact review grant. After the
-- one-way cutover, all active season-bound grants become authoritative.
create or replace function private.parent_authorized_member_seasons(
  p_parent_account_id uuid
)
returns table(member_season_id uuid)
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select distinct authorized.member_season_id
  from (
    select grant_row.member_season_id
    from private.parent_portal_grants grant_row
    join private.parent_accounts account
      on account.id = grant_row.parent_account_id
      and account.email_normalized = grant_row.email_normalized
    join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
      and member_season.participation_status = 'active'
    cross join app.app_settings settings
    where settings.id = true
      and grant_row.parent_account_id = p_parent_account_id
      and grant_row.status = 'active'
      and (
        private.parent_access_v2_enabled()
        or member_season.season_id = settings.active_season_id
      )

    union all

    select grant_row.member_season_id
    from private.parent_portal_grants grant_row
    join private.parent_accounts account
      on account.id = grant_row.parent_account_id
      and account.email_normalized = grant_row.email_normalized
    join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
      and member_season.participation_status = 'active'
    join private.parent_member_links link
      on link.id = grant_row.legacy_link_id
      and link.parent_account_id = grant_row.parent_account_id
      and link.member_id = member_season.member_id
      and link.unlinked_at is null
    join app.app_settings settings
      on settings.id = true
      and settings.active_season_id = member_season.season_id
    where not private.parent_access_v2_enabled()
      and grant_row.parent_account_id = p_parent_account_id
      and grant_row.status = 'review_required'
      and grant_row.source = 'legacy_review'
  ) authorized;
$$;

create or replace function private.parent_account_has_portal_access(
  p_parent_account_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select exists(
    select 1
    from private.parent_authorized_member_seasons(p_parent_account_id)
  );
$$;

revoke all on function private.parent_authorized_member_seasons(uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.parent_account_has_portal_access(uuid)
  from public, anon, authenticated, service_role;

create or replace function private.refresh_parent_legacy_projection(
  p_parent_account_id uuid,
  p_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  should_link boolean;
begin
  if p_parent_account_id is null or p_member_id is null
    or private.parent_access_v2_enabled()
  then
    return;
  end if;

  select exists(
    select 1
    from app.app_settings settings
    join app.member_seasons member_season
      on member_season.member_id = p_member_id
      and member_season.season_id = settings.active_season_id
      and member_season.participation_status = 'active'
    join private.parent_portal_grants grant_row
      on grant_row.member_season_id = member_season.id
      and grant_row.parent_account_id = p_parent_account_id
    where settings.id = true
      and (
        grant_row.status = 'active'
        or (
          grant_row.status = 'review_required'
          and grant_row.source = 'legacy_review'
        )
      )
  ) into should_link;

  perform set_config('app.parent_access_internal', 'on', true);
  if should_link then
    insert into private.parent_member_links(
      parent_account_id,
      member_id,
      unlinked_at
    ) values (
      p_parent_account_id,
      p_member_id,
      null
    )
    on conflict (parent_account_id, member_id) do update
      set unlinked_at = null,
          linked_at = timezone('utc', now());
  else
    update private.parent_member_links
    set unlinked_at = coalesce(unlinked_at, timezone('utc', now()))
    where parent_account_id = p_parent_account_id
      and member_id = p_member_id;
  end if;
  perform set_config('app.parent_access_internal', 'off', true);
exception when others then
  perform set_config('app.parent_access_internal', 'off', true);
  raise;
end;
$$;

revoke all on function private.refresh_parent_legacy_projection(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function private.parent_access_cutover_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  with metrics as (
    select
      private.parent_access_v2_enabled() enabled,
      (
        select count(*)::integer
        from private.parent_portal_grants grant_row
        where grant_row.status in ('pending_account', 'review_required')
      ) unresolved_grants,
      (
        select count(*)::integer
        from private.parent_portal_grants grant_row
        where grant_row.status = 'active'
      ) active_grants,
      (
        select count(*)::integer
        from private.parent_member_links link
        where link.unlinked_at is null
      ) active_legacy_links,
      (
        select count(*)::integer
        from private.parent_member_links link
        where link.unlinked_at is null
          and not exists(
            select 1
            from private.parent_portal_grants grant_row
            join private.parent_accounts account
              on account.id = grant_row.parent_account_id
              and account.email_normalized = grant_row.email_normalized
            join app.member_seasons member_season
              on member_season.id = grant_row.member_season_id
              and member_season.member_id = link.member_id
              and member_season.participation_status = 'active'
            join app.app_settings settings
              on settings.id = true
              and settings.active_season_id = member_season.season_id
            where grant_row.parent_account_id = link.parent_account_id
              and grant_row.status = 'active'
          )
      ) unresolved_legacy_links,
      (
        select count(*)::integer
        from private.parent_sessions session
        where session.revoked_at is null
          and session.expires_at > timezone('utc', now())
          and not exists(
            select 1
            from private.parent_portal_grants grant_row
            join app.member_seasons member_season
              on member_season.id = grant_row.member_season_id
              and member_season.participation_status = 'active'
            where grant_row.parent_account_id = session.parent_account_id
              and grant_row.status = 'active'
          )
      ) sessions_to_revoke,
      encode(extensions.digest(coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', grant_row.id,
          'memberSeasonId', grant_row.member_season_id,
          'accountId', grant_row.parent_account_id,
          'status', grant_row.status,
          'updatedAt', grant_row.updated_at
        ) order by grant_row.id)
        from private.parent_portal_grants grant_row
      ), '[]'::jsonb)::text || ':' || coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', link.id,
          'accountId', link.parent_account_id,
          'memberId', link.member_id,
          'unlinkedAt', link.unlinked_at
        ) order by link.id)
        from private.parent_member_links link
      ), '[]'::jsonb)::text || ':' || coalesce((
        select settings.active_season_id::text
        from app.app_settings settings
        where settings.id = true
      ), ''), 'sha256'), 'hex') revision
  )
  select jsonb_build_object(
    'enabled', metrics.enabled,
    'ready', metrics.unresolved_grants = 0
      and metrics.unresolved_legacy_links = 0,
    'unresolvedGrantCount', metrics.unresolved_grants,
    'activeGrantCount', metrics.active_grants,
    'activeLegacyLinkCount', metrics.active_legacy_links,
    'unresolvedLegacyLinkCount', metrics.unresolved_legacy_links,
    'sessionsToRevokeCount', metrics.sessions_to_revoke,
    'revision', metrics.revision
  )
  from metrics;
$$;

create or replace function app.get_parent_access_cutover_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return private.parent_access_cutover_snapshot();
end;
$$;

create or replace function app.enable_parent_access_grants_v2(
  p_expected_revision text,
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
  revoked_sessions integer := 0;
begin
  if p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
  then
    raise exception 'PARENT_ACCESS_CUTOVER_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-grants-global', 0)
  );
  lock table app.app_settings in share row exclusive mode;
  lock table private.parent_portal_grants in share row exclusive mode;
  lock table private.parent_member_links in share row exclusive mode;
  lock table private.parent_sessions in share row exclusive mode;
  lock table app.member_seasons in share row exclusive mode;
  lock table app.release_feature_flags in share row exclusive mode;

  snapshot := private.parent_access_cutover_snapshot();
  if (snapshot->>'enabled')::boolean then
    return snapshot || jsonb_build_object(
      'sessionsRevoked', 0,
      'reused', true
    );
  end if;
  if snapshot->>'revision' <> p_expected_revision then
    raise exception 'PARENT_ACCESS_CUTOVER_STALE' using errcode = '40001';
  end if;
  if not (snapshot->>'ready')::boolean then
    raise exception 'PARENT_ACCESS_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;

  update private.parent_sessions session
  set revoked_at = timezone('utc', now())
  where session.revoked_at is null
    and session.expires_at > timezone('utc', now())
    and not exists(
      select 1
      from private.parent_portal_grants grant_row
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
        and member_season.participation_status = 'active'
      where grant_row.parent_account_id = session.parent_account_id
        and grant_row.status = 'active'
    );
  get diagnostics revoked_sessions = row_count;

  update app.release_feature_flags
  set enabled = true,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key = 'parent_access_grants_v2';

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'parent.access.cutover_enabled',
    'release_feature_flag',
    null,
    jsonb_build_object(
      'activeGrantCount', (snapshot->>'activeGrantCount')::integer,
      'activeLegacyLinkCount',
        (snapshot->>'activeLegacyLinkCount')::integer,
      'sessionsRevoked', revoked_sessions
    ),
    p_correlation_id
  );

  return private.parent_access_cutover_snapshot() || jsonb_build_object(
    'sessionsRevoked', revoked_sessions,
    'reused', false
  );
end;
$$;

revoke all on function private.parent_access_v2_enabled()
  from public, anon, authenticated, service_role;
revoke all on function private.parent_access_cutover_snapshot()
  from public, anon, authenticated, service_role;

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
        or lower(member.relation_number) like '%' || normalized_search || '%'
        or lower(member.email) like '%' || normalized_search || '%'
        or lower(coalesce(member_season.team_name, '')) like '%' || normalized_search || '%'
      )
  ),
  page as (
    select *
    from visible
    order by lower(last_name), lower(first_name), relation_number, member_season_id
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
          when length(trim(page.email)) = 0 then 'missing'
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
      ) order by lower(page.last_name), lower(page.first_name), page.relation_number)
      from page
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function private.parent_activation_preview(
  p_season_id uuid,
  p_member_season_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  if p_season_id is null
    or p_member_season_ids is null
    or coalesce(array_length(p_member_season_ids, 1), 0) not between 1 and 500
    or (select count(*) from unnest(p_member_season_ids) item)
      <> (select count(distinct item) from unnest(p_member_season_ids) item)
    or exists(select 1 from unnest(p_member_season_ids) item where item is null)
  then
    raise exception 'PARENT_ACCESS_SELECTION_INVALID' using errcode = '22023';
  end if;
  if not exists(
    select 1 from app.seasons season
    where season.id = p_season_id and season.status = 'open'
  ) then
    raise exception 'PARENT_ACCESS_SEASON_NOT_OPEN' using errcode = '23514';
  end if;

  with selected as (
    select item.member_season_id
    from unnest(p_member_season_ids) item(member_season_id)
  ),
  base as (
    select selected.member_season_id,
      member_season.member_id,
      member_season.season_id,
      member_season.team_name,
      member_season.participation_status,
      member_season.reconciliation_status,
      member.relation_number,
      member.first_name,
      member.insertion,
      member.last_name,
      member.email,
      lower(trim(member.email)) email_normalized,
      account.id existing_account_id,
      active_same.id active_grant_id,
      exists(
        select 1
        from private.parent_portal_grants other_grant
        where other_grant.member_season_id = selected.member_season_id
          and other_grant.status in ('pending_account', 'review_required', 'active')
          and other_grant.email_normalized <> lower(trim(member.email))
      ) conflicting_open_grant,
      exists(
        select 1
        from private.parent_member_links link
        join private.parent_accounts linked_account
          on linked_account.id = link.parent_account_id
        where link.member_id = member_season.member_id
          and link.unlinked_at is null
          and linked_account.email_normalized <> lower(trim(member.email))
      ) suspicious_legacy_link
    from selected
    left join app.member_seasons member_season
      on member_season.id = selected.member_season_id
    left join app.members member on member.id = member_season.member_id
    left join private.parent_accounts account
      on account.email_normalized = lower(trim(member.email))
    left join private.parent_portal_grants active_same
      on active_same.member_season_id = selected.member_season_id
      and active_same.email_normalized = lower(trim(member.email))
      and active_same.status = 'active'
  ),
  assessed as (
    select base.*,
      array_remove(array[
        case when base.member_id is null then 'member_season_not_found' end,
        case when base.member_id is not null and base.season_id <> p_season_id then 'season_mismatch' end,
        case when base.member_id is not null
          and base.participation_status <> 'active' then 'member_not_active' end,
        case when base.member_id is not null
          and base.reconciliation_status <> 'resolved' then 'member_season_unresolved' end,
        case when base.member_id is not null
          and not private.parent_access_email_valid(base.email) then 'email_invalid' end,
        case when base.conflicting_open_grant then 'conflicting_portal_grant' end,
        case when base.suspicious_legacy_link then 'suspicious_family_link' end
      ], null)::text[] blockers
    from base
  ),
  classified as (
    select assessed.*,
      case
        when cardinality(blockers) > 0 then 'blocked'
        when active_grant_id is not null then 'unchanged'
        else 'eligible'
      end row_status,
      case
        when private.parent_access_email_valid(email) then email_normalized
        else 'invalid:' || member_season_id::text
      end group_key
    from assessed
  ),
  grouped as (
    select group_key,
      max(email_normalized) filter (
        where private.parent_access_email_valid(email)
      ) email_normalized,
      bool_or(existing_account_id is not null) existing_account,
      bool_or(row_status = 'eligible') invitation_required,
      case
        when bool_or(row_status = 'blocked') then 'blocked'
        when bool_or(row_status = 'eligible') then 'eligible'
        else 'unchanged'
      end group_status,
      coalesce((
        select jsonb_agg(distinct blocker)
        from classified classified_blockers
        cross join lateral unnest(classified_blockers.blockers) blocker
        where classified_blockers.group_key = classified_group.group_key
      ), '[]'::jsonb) blockers,
      jsonb_agg(jsonb_build_object(
        'memberSeasonId', member_season_id,
        'memberId', member_id,
        'relationNumber', relation_number,
        'firstName', first_name,
        'insertion', insertion,
        'lastName', last_name,
        'team', team_name,
        'status', row_status,
        'activeGrantId', active_grant_id
      ) order by lower(last_name) nulls last, lower(first_name) nulls last, member_season_id) members,
      max((
        select count(*)
        from app.member_seasons other_member_season
        join app.members other_member on other_member.id = other_member_season.member_id
        where other_member_season.season_id = p_season_id
          and other_member_season.participation_status = 'active'
          and other_member_season.reconciliation_status = 'resolved'
          and private.parent_access_email_valid(other_member.email)
          and lower(trim(other_member.email)) = classified_group.email_normalized
          and other_member_season.id <> all(p_member_season_ids)
      ))::integer non_selected_count
    from classified classified_group
    group by group_key
  )
  select jsonb_build_object(
    'operation', 'activate',
    'seasonId', p_season_id,
    'seasonName', (select season.name from app.seasons season where season.id = p_season_id),
    'selectionCount', (select count(*) from classified),
    'eligibleCount', (select count(*) from classified where row_status = 'eligible'),
    'unchangedCount', (select count(*) from classified where row_status = 'unchanged'),
    'blockedCount', (select count(*) from classified where row_status = 'blocked'),
    'revision', private.parent_activation_revision(p_season_id, p_member_season_ids),
    'mailTemplate', (
      select jsonb_build_object(
        'key', template.template_key,
        'version', template.version,
        'subjectSource', template.subject_source,
        'bodySource', template.body_source,
        'allowedShortcodes', template.allowed_shortcodes,
        'clubName', settings.club_name,
        'contactEmail', settings.contact_email
      )
      from app.email_templates template
      cross join app.app_settings settings
      where settings.id = true
        and template.template_key = 'portal_access_invite'
        and template.active
    ),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', encode(extensions.digest(grouped.group_key, 'sha256'), 'hex'),
        'email', grouped.email_normalized,
        'existingAccount', grouped.existing_account,
        'invitationRequired', grouped.invitation_required,
        'nonSelectedCount', grouped.non_selected_count,
        'status', grouped.group_status,
        'blockers', grouped.blockers,
        'members', grouped.members
      ) order by grouped.email_normalized nulls last, grouped.group_key)
      from grouped
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function app.preview_parent_portal_activation(
  p_season_id uuid,
  p_member_season_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return private.parent_activation_preview(p_season_id, p_member_season_ids);
end;
$$;

create or replace function private.parent_revocation_preview(
  p_season_id uuid,
  p_grant_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  if p_season_id is null
    or p_grant_ids is null
    or coalesce(array_length(p_grant_ids, 1), 0) not between 1 and 500
    or (select count(*) from unnest(p_grant_ids) item)
      <> (select count(distinct item) from unnest(p_grant_ids) item)
    or exists(select 1 from unnest(p_grant_ids) item where item is null)
  then
    raise exception 'PARENT_ACCESS_SELECTION_INVALID' using errcode = '22023';
  end if;
  if not exists(select 1 from app.seasons season where season.id = p_season_id) then
    raise exception 'PARENT_ACCESS_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  with selected as (
    select item.grant_id
    from unnest(p_grant_ids) item(grant_id)
  ),
  classified as (
    select selected.grant_id,
      grant_row.member_season_id,
      grant_row.email_normalized,
      grant_row.parent_account_id,
      grant_row.status,
      member.relation_number,
      member.first_name,
      member.insertion,
      member.last_name,
      member_season.team_name,
      array_remove(array[
        case when grant_row.id is null then 'grant_not_found' end,
        case when grant_row.id is not null
          and member_season.season_id <> p_season_id then 'season_mismatch' end
      ], null)::text[] blockers
    from selected
    left join private.parent_portal_grants grant_row
      on grant_row.id = selected.grant_id
    left join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
    left join app.members member on member.id = member_season.member_id
  ),
  enriched as (
    select classified.*,
      case
        when cardinality(classified.blockers) > 0 then 'blocked'
        when classified.status = 'revoked' then 'unchanged'
        else 'eligible'
      end row_status,
      coalesce(
        classified.email_normalized,
        'invalid:' || classified.grant_id::text
      ) group_key
    from classified
  ),
  grouped as (
    select enriched.group_key,
      max(enriched.email_normalized) email_normalized,
      bool_or(enriched.parent_account_id is not null) existing_account,
      case
        when bool_or(enriched.row_status = 'blocked') then 'blocked'
        when bool_or(enriched.row_status = 'eligible') then 'eligible'
        else 'unchanged'
      end group_status,
      coalesce((
        select jsonb_agg(distinct blocker)
        from enriched blocker_row
        cross join lateral unnest(blocker_row.blockers) blocker
        where blocker_row.group_key = enriched.group_key
      ), '[]'::jsonb) blockers,
      jsonb_agg(jsonb_build_object(
        'memberSeasonId', enriched.member_season_id,
        'memberId', null,
        'relationNumber', enriched.relation_number,
        'firstName', enriched.first_name,
        'insertion', enriched.insertion,
        'lastName', enriched.last_name,
        'team', enriched.team_name,
        'status', enriched.row_status,
        'activeGrantId', enriched.grant_id
      ) order by lower(enriched.last_name) nulls last,
        lower(enriched.first_name) nulls last,
        enriched.grant_id) members,
      case when max(enriched.email_normalized) is null then 0 else (
        select count(*)::integer
        from private.parent_portal_grants other_grant
        join app.member_seasons other_member_season
          on other_member_season.id = other_grant.member_season_id
        where other_member_season.season_id = p_season_id
          and other_grant.status = 'active'
          and other_grant.email_normalized = max(enriched.email_normalized)
          and other_grant.id <> all(p_grant_ids)
      ) end non_selected_count
    from enriched
    group by enriched.group_key
  )
  select jsonb_build_object(
    'operation', 'revoke',
    'seasonId', p_season_id,
    'seasonName', (select season.name from app.seasons season where season.id = p_season_id),
    'selectionCount', (select count(*) from enriched),
    'eligibleCount', (select count(*) from enriched
      where row_status = 'eligible'),
    'unchangedCount', (select count(*) from enriched
      where row_status = 'unchanged'),
    'blockedCount', (select count(*) from enriched
      where row_status = 'blocked'),
    'revision', private.parent_revocation_revision(p_season_id, p_grant_ids),
    'mailTemplate', null,
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', encode(extensions.digest(
          grouped.group_key,
          'sha256'
        ), 'hex'),
        'email', grouped.email_normalized,
        'existingAccount', grouped.existing_account,
        'invitationRequired', false,
        'nonSelectedCount', grouped.non_selected_count,
        'status', grouped.group_status,
        'blockers', grouped.blockers,
        'members', grouped.members
      ) order by grouped.email_normalized nulls last, grouped.group_key)
      from grouped
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function app.preview_parent_portal_revocation(
  p_season_id uuid,
  p_grant_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return private.parent_revocation_preview(p_season_id, p_grant_ids);
end;
$$;

revoke all on function private.parent_activation_preview(uuid, uuid[])
  from public, anon, authenticated, service_role;
revoke all on function private.parent_revocation_preview(uuid, uuid[])
  from public, anon, authenticated, service_role;

alter table app.email_templates
  drop constraint if exists email_templates_template_key_check;
alter table app.email_templates
  add constraint email_templates_template_key_check check (template_key in (
    'verification_code',
    'portal_access_invite',
    'payment_request',
    'payment_received',
    'ready_for_pickup',
    'payment_reminder',
    'qr_code_resent'
  ));

insert into app.email_templates(
  template_key,
  subject_source,
  body_source,
  allowed_shortcodes
) values (
  'portal_access_invite',
  'Uw toegang tot het tenueportaal van {{clubnaam}}',
  'De kledingcommissie heeft uw toegang tot het tenueportaal geactiveerd. Open {{portaal_url}} en vraag daar zelf een eenmalige verificatiecode aan. Deze uitnodiging bevat geen inlogcode of login-token. Vragen? {{contact_email}}',
  array['{{portaal_url}}', '{{clubnaam}}', '{{contact_email}}']
)
on conflict (template_key) do nothing;

do $$
begin
  if exists(
    select 1 from private.email_jobs job where job.order_id is null
  ) then
    raise exception 'PARENT_ACCESS_EMAIL_CONTEXT_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;
end;
$$;

alter table private.email_jobs
  add column context_kind text not null default 'order'
    check (context_kind in ('order', 'portal_access')),
  add column parent_account_id uuid references private.parent_accounts(id) on delete restrict,
  add column parent_access_batch_id uuid references private.parent_access_batches(id) on delete restrict;

alter table private.email_jobs
  drop constraint email_jobs_durable_snapshot_check;
alter table private.email_jobs
  add constraint email_jobs_durable_snapshot_check check (
    template_id is not null
    and template_version is not null
    and template_version > 0
    and subject_source_snapshot is not null
    and body_source_snapshot is not null
    and allowed_shortcodes_snapshot is not null
  ),
  add constraint email_jobs_context_check check (
    (
      context_kind = 'order'
      and order_id is not null
      and parent_account_id is null
      and parent_access_batch_id is null
      and template_key <> 'portal_access_invite'
    )
    or (
      context_kind = 'portal_access'
      and order_id is null
      and parent_account_id is not null
      and parent_access_batch_id is not null
      and template_key = 'portal_access_invite'
      and kind = 'transactional'
      and batch_id is null
    )
  );

create index email_jobs_parent_account_created_idx
  on private.email_jobs(parent_account_id, created_at desc)
  where parent_account_id is not null;
create index email_jobs_parent_access_batch_idx
  on private.email_jobs(parent_access_batch_id, created_at)
  where parent_access_batch_id is not null;
create unique index email_jobs_one_parent_access_invite_idx
  on private.email_jobs(parent_access_batch_id, parent_account_id)
  where context_kind = 'portal_access';

create or replace function private.guard_email_job_snapshot()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_template app.email_templates%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.template_id is null
      or new.template_key = 'verification_code'
    then
      raise exception 'DURABLE_EMAIL_CONTEXT_REQUIRED' using errcode = '23514';
    end if;
    select * into target_template
    from app.email_templates template
    where template.id = new.template_id and template.active;
    if not found or target_template.template_key <> new.template_key then
      raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514';
    end if;
    if (
      new.context_kind = 'order'
      and (
        new.order_id is null
        or new.parent_account_id is not null
        or new.parent_access_batch_id is not null
        or new.template_key = 'portal_access_invite'
      )
    ) or (
      new.context_kind = 'portal_access'
      and (
        new.order_id is not null
        or new.parent_account_id is null
        or new.parent_access_batch_id is null
        or new.template_key <> 'portal_access_invite'
        or new.kind <> 'transactional'
        or new.batch_id is not null
        or new.recipient_email <> (
          select account.email_normalized
          from private.parent_accounts account
          where account.id = new.parent_account_id
        )
      )
    ) then
      raise exception 'EMAIL_TEMPLATE_CONTEXT_INVALID' using errcode = '23514';
    end if;
    new.template_version := target_template.version;
    new.subject_source_snapshot := target_template.subject_source;
    new.body_source_snapshot := target_template.body_source;
    new.allowed_shortcodes_snapshot := target_template.allowed_shortcodes;
  elsif (
    new.context_kind is distinct from old.context_kind
    or new.kind is distinct from old.kind
    or new.order_id is distinct from old.order_id
    or new.parent_account_id is distinct from old.parent_account_id
    or new.parent_access_batch_id is distinct from old.parent_access_batch_id
    or new.batch_id is distinct from old.batch_id
    or new.template_id is distinct from old.template_id
    or new.template_key is distinct from old.template_key
    or new.recipient_email is distinct from old.recipient_email
    or new.payload is distinct from old.payload
    or new.idempotency_key is distinct from old.idempotency_key
    or new.template_version is distinct from old.template_version
    or new.subject_source_snapshot is distinct from old.subject_source_snapshot
    or new.body_source_snapshot is distinct from old.body_source_snapshot
    or new.allowed_shortcodes_snapshot is distinct from old.allowed_shortcodes_snapshot
  ) then
    raise exception 'EMAIL_JOB_SNAPSHOT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.enqueue_parent_access_invite(
  p_parent_account_id uuid,
  p_parent_access_batch_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_template app.email_templates%rowtype;
  target_batch private.parent_access_batches%rowtype;
  target_account private.parent_accounts%rowtype;
  message_payload jsonb;
  job_id uuid;
  idempotency text;
begin
  select * into target_batch
  from private.parent_access_batches batch
  where batch.id = p_parent_access_batch_id
    and batch.operation = 'activate';
  if not found then
    raise exception 'PARENT_ACCESS_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into target_account
  from private.parent_accounts account
  where account.id = p_parent_account_id;
  if not found then
    raise exception 'PARENT_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into target_template
  from app.email_templates template
  where template.template_key = 'portal_access_invite'
    and template.active;
  if not found then
    raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514';
  end if;

  if not exists(
    select 1
    from private.parent_access_batch_items batch_item
    join private.parent_portal_grants grant_row
      on grant_row.id = batch_item.grant_id
    where batch_item.batch_id = target_batch.id
      and batch_item.outcome = 'activated'
      and grant_row.parent_account_id = target_account.id
      and grant_row.status = 'active'
  ) then
    raise exception 'PARENT_ACCESS_INVITE_EMPTY' using errcode = '23514';
  end if;
  select jsonb_build_object(
    'parentAccountId', target_account.id,
    'clubName', settings.club_name,
    'contactEmail', settings.contact_email
  ) into message_payload
  from app.app_settings settings
  where settings.id = true;

  idempotency := 'parent-access:' || target_batch.batch_key::text
    || ':' || target_account.id::text;
  insert into private.email_jobs(
    context_kind,
    kind,
    recipient_email,
    template_key,
    template_id,
    parent_account_id,
    parent_access_batch_id,
    idempotency_key,
    payload,
    status,
    available_at
  ) values (
    'portal_access',
    'transactional',
    target_account.email_normalized,
    target_template.template_key,
    target_template.id,
    target_account.id,
    target_batch.id,
    idempotency,
    message_payload,
    'queued',
    timezone('utc', now())
  )
  on conflict (idempotency_key) where idempotency_key is not null do nothing
  returning id into job_id;
  if job_id is null then
    select job.id into job_id
    from private.email_jobs job
    where job.idempotency_key = idempotency;
  end if;
  return job_id;
end;
$$;

revoke all on function private.guard_email_job_snapshot()
  from public, anon, authenticated, service_role;
revoke all on function private.enqueue_parent_access_invite(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app.claim_email_jobs_v2(
  p_claim_token uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  safe_limit integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 25);

  -- A grant can disappear after enqueue (or the member-season can become
  -- inactive). Park such invitations before selecting work so a route-only
  -- invitation never remains silently claimable.
  update private.email_jobs invite_job
  set status = 'failed',
      completed_at = timezone('utc', now()),
      last_error = 'access_inactive_before_send',
      updated_at = timezone('utc', now())
  where invite_job.context_kind = 'portal_access'
    and invite_job.status in ('queued', 'retry')
    and not exists(
      select 1
      from private.parent_access_batch_items batch_item
      join private.parent_portal_grants grant_row
        on grant_row.id = batch_item.grant_id
        and grant_row.parent_account_id = invite_job.parent_account_id
        and grant_row.status = 'active'
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
        and member_season.participation_status = 'active'
      where batch_item.batch_id = invite_job.parent_access_batch_id
        and batch_item.outcome = 'activated'
    );

  with candidates as (
    select job.id
    from private.email_jobs job
    where job.template_version is not null
      and job.status in ('queued', 'retry')
      and job.attempts < 5
      and job.available_at <= timezone('utc', now())
      and (
        job.context_kind = 'order'
        or exists(
          select 1
          from private.parent_access_batch_items batch_item
          join private.parent_portal_grants grant_row
            on grant_row.id = batch_item.grant_id
            and grant_row.parent_account_id = job.parent_account_id
            and grant_row.status = 'active'
          join app.member_seasons member_season
            on member_season.id = grant_row.member_season_id
            and member_season.participation_status = 'active'
          where batch_item.batch_id = job.parent_access_batch_id
            and batch_item.outcome = 'activated'
        )
      )
    order by job.available_at, job.created_at
    for update skip locked
    limit safe_limit
  ),
  claimed as (
    update private.email_jobs job
    set status = 'processing',
        attempts = attempts + 1,
        claim_token = p_claim_token,
        claimed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    from candidates
    where job.id = candidates.id
    returning job.*
  )
  select jsonb_build_object(
    'claimToken', p_claim_token,
    'jobs', coalesce(jsonb_agg(jsonb_build_object(
      'id', claimed.id,
      'kind', claimed.kind,
      'contextKind', claimed.context_kind,
      'recipientEmail', claimed.recipient_email,
      'templateKey', claimed.template_key,
      'templateVersion', claimed.template_version,
      'subjectSource', claimed.subject_source_snapshot,
      'bodySource', claimed.body_source_snapshot,
      'allowedShortcodes', claimed.allowed_shortcodes_snapshot,
      'orderId', claimed.order_id,
      'parentAccountId', claimed.parent_account_id,
      'payload', claimed.payload,
      'attempt', claimed.attempts
    ) order by claimed.created_at), '[]'::jsonb)
  ) into result
  from claimed;
  return result;
end;
$$;

revoke all on function app.claim_email_jobs_v2(uuid, integer)
  from public, anon, authenticated;
grant execute on function app.claim_email_jobs_v2(uuid, integer)
  to service_role;

create or replace function app.authorize_claimed_email_job(
  p_job_id uuid,
  p_claim_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_job private.email_jobs%rowtype;
  access_valid boolean;
begin
  if p_job_id is null or p_claim_token is null then
    return false;
  end if;
  select * into target_job
  from private.email_jobs job
  where job.id = p_job_id
    and job.status = 'processing'
    and job.claim_token = p_claim_token
  for update;
  if not found then
    return false;
  end if;
  if target_job.context_kind = 'order' then
    return true;
  end if;

  select exists(
    select 1
    from private.parent_access_batch_items batch_item
    join private.parent_portal_grants grant_row
      on grant_row.id = batch_item.grant_id
      and grant_row.parent_account_id = target_job.parent_account_id
      and grant_row.status = 'active'
    join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
      and member_season.participation_status = 'active'
    where batch_item.batch_id = target_job.parent_access_batch_id
      and batch_item.outcome = 'activated'
  ) into access_valid;
  if access_valid then
    return true;
  end if;

  update private.email_jobs
  set status = 'failed',
      completed_at = timezone('utc', now()),
      last_error = 'access_inactive_before_send',
      updated_at = timezone('utc', now())
  where id = target_job.id;
  return false;
end;
$$;

revoke all on function app.authorize_claimed_email_job(uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.authorize_claimed_email_job(uuid, uuid)
  to service_role;

-- Keep the existing order-only claim shape for safe application rollback.
create or replace function app.claim_email_jobs(
  p_claim_token uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  safe_limit integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 25);
  with candidates as (
    select job.id
    from private.email_jobs job
    where job.context_kind = 'order'
      and job.order_id is not null
      and job.template_version is not null
      and job.status in ('queued', 'retry')
      and job.attempts < 5
      and job.available_at <= timezone('utc', now())
    order by job.available_at, job.created_at
    for update skip locked
    limit safe_limit
  ),
  claimed as (
    update private.email_jobs job
    set status = 'processing',
        attempts = attempts + 1,
        claim_token = p_claim_token,
        claimed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    from candidates
    where job.id = candidates.id
    returning job.*
  )
  select jsonb_build_object(
    'claimToken', p_claim_token,
    'jobs', coalesce(jsonb_agg(jsonb_build_object(
      'id', claimed.id,
      'kind', claimed.kind,
      'recipientEmail', claimed.recipient_email,
      'templateKey', claimed.template_key,
      'templateVersion', claimed.template_version,
      'subjectSource', claimed.subject_source_snapshot,
      'bodySource', claimed.body_source_snapshot,
      'allowedShortcodes', claimed.allowed_shortcodes_snapshot,
      'orderId', claimed.order_id,
      'payload', claimed.payload,
      'attempt', claimed.attempts
    ) order by claimed.created_at), '[]'::jsonb)
  ) into result
  from claimed;
  return result;
end;
$$;

revoke all on function app.claim_email_jobs(uuid, integer)
  from public, anon, authenticated;
grant execute on function app.claim_email_jobs(uuid, integer)
  to service_role;

create or replace function app.activate_parent_portal_access(
  p_season_id uuid,
  p_member_season_ids uuid[],
  p_expected_revision text,
  p_batch_key uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  request_hash text;
  preview jsonb;
  target_batch private.parent_access_batches%rowtype;
  target_record record;
  target_account_id uuid;
  target_grant private.parent_portal_grants%rowtype;
  now_utc timestamptz := timezone('utc', now());
  activated_count integer := 0;
  unchanged_count integer := 0;
  invite_count integer := 0;
  operation_result jsonb;
begin
  if p_season_id is null
    or p_member_season_ids is null
    or coalesce(array_length(p_member_season_ids, 1), 0) not between 1 and 500
    or (select count(*) from unnest(p_member_season_ids) item)
      <> (select count(distinct item) from unnest(p_member_season_ids) item)
    or exists(
      select 1 from unnest(p_member_season_ids) item where item is null
    )
    or p_batch_key is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
  then
    raise exception 'PARENT_ACCESS_COMMIT_INVALID' using errcode = '22023';
  end if;
  request_hash := encode(extensions.digest(jsonb_build_object(
    'operation', 'activate',
    'seasonId', p_season_id,
    'memberSeasonIds', (
      select jsonb_agg(item order by item)
      from unnest(p_member_season_ids) item
    ),
    'expectedRevision', p_expected_revision
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-batch:' || p_batch_key::text, 0)
  );
  select * into target_batch
  from private.parent_access_batches batch
  where batch.batch_key = p_batch_key
  for update;
  if found then
    if target_batch.operation <> 'activate'
      or target_batch.season_id <> p_season_id
      or target_batch.selection_hash <> request_hash
      or target_batch.actor_user_id <> actor
    then
      raise exception 'PARENT_ACCESS_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if target_batch.result is null then
      raise exception 'PARENT_ACCESS_BATCH_INCOMPLETE' using errcode = '40001';
    end if;
    return target_batch.result || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-grants-global', 0)
  );
  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-season:' || p_season_id::text, 0)
  );
  perform 1
  from app.app_settings settings
  where settings.id = true
  for update;
  perform 1
  from app.email_templates template
  where template.template_key = 'portal_access_invite'
  for update;
  -- Lock member identity before member-season rows. This both closes the
  -- email TOCTOU and follows the same order as a concurrent member update.
  perform 1
  from app.members member
  join app.member_seasons member_season
    on member_season.member_id = member.id
  where member_season.id = any(p_member_season_ids)
  order by member.id
  for update of member;
  perform 1
  from app.member_seasons member_season
  where member_season.id = any(p_member_season_ids)
  order by member_season.id
  for update;
  perform 1
  from private.parent_portal_grants grant_row
  where grant_row.member_season_id = any(p_member_season_ids)
  order by grant_row.id
  for update;

  preview := private.parent_activation_preview(
    p_season_id,
    p_member_season_ids
  );
  if preview->>'revision' <> p_expected_revision then
    raise exception 'PARENT_ACCESS_PREVIEW_STALE' using errcode = '40001';
  end if;
  if (preview->>'blockedCount')::integer > 0 then
    raise exception 'PARENT_ACCESS_SELECTION_BLOCKED' using errcode = '23514';
  end if;

  insert into private.parent_access_batches(
    batch_key,
    operation,
    season_id,
    selection_hash,
    selected_count,
    actor_user_id
  ) values (
    p_batch_key,
    'activate',
    p_season_id,
    request_hash,
    array_length(p_member_season_ids, 1),
    actor
  )
  returning * into target_batch;

  for target_record in
    select member_season.id member_season_id,
      member_season.member_id,
      member_season.season_id,
      lower(trim(member.email)) email_normalized
    from app.member_seasons member_season
    join app.members member on member.id = member_season.member_id
    where member_season.id = any(p_member_season_ids)
    order by member_season.id
  loop
    select * into target_grant
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = target_record.member_season_id
      and grant_row.email_normalized = target_record.email_normalized
      and grant_row.status = 'active'
    for update;
    if found then
      perform private.refresh_parent_legacy_projection(
        target_grant.parent_account_id,
        target_record.member_id
      );
      insert into private.parent_access_batch_items(
        batch_id,
        member_season_id,
        grant_id,
        outcome
      ) values (
        target_batch.id,
        target_record.member_season_id,
        target_grant.id,
        'unchanged'
      );
      unchanged_count := unchanged_count + 1;
      continue;
    end if;

    insert into private.parent_accounts(email_normalized)
    values(target_record.email_normalized)
    on conflict (email_normalized) do update
      set email_normalized = excluded.email_normalized
    returning id into target_account_id;

    select * into target_grant
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = target_record.member_season_id
      and grant_row.email_normalized = target_record.email_normalized
      and grant_row.status in ('pending_account', 'review_required')
    order by grant_row.updated_at desc, grant_row.id
    limit 1
    for update;

    if found then
      update private.parent_portal_grants
      set parent_account_id = target_account_id,
          status = 'active',
          source = 'administrator',
          granted_by = actor,
          granted_at = now_utc,
          revoked_by = null,
          revoked_at = null,
          revoked_reason = null,
          updated_at = now_utc
      where id = target_grant.id
      returning * into target_grant;
    else
      insert into private.parent_portal_grants(
        member_season_id,
        email_normalized,
        parent_account_id,
        status,
        source,
        granted_by,
        granted_at
      ) values (
        target_record.member_season_id,
        target_record.email_normalized,
        target_account_id,
        'active',
        'administrator',
        actor,
        now_utc
      )
      returning * into target_grant;
    end if;

    perform private.refresh_parent_legacy_projection(
      target_account_id,
      target_record.member_id
    );
    insert into private.parent_access_batch_items(
      batch_id,
      member_season_id,
      grant_id,
      outcome
    ) values (
      target_batch.id,
      target_record.member_season_id,
      target_grant.id,
      'activated'
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
      'parent.access.activated',
      'parent_portal_grant',
      target_grant.id,
      jsonb_build_object(
        'memberSeasonId', target_record.member_season_id,
        'seasonId', p_season_id,
        'batchId', target_batch.id
      ),
      p_correlation_id
    );
    activated_count := activated_count + 1;
  end loop;

  for target_account_id in
    select distinct grant_row.parent_account_id
    from private.parent_access_batch_items batch_item
    join private.parent_portal_grants grant_row
      on grant_row.id = batch_item.grant_id
    where batch_item.batch_id = target_batch.id
      and batch_item.outcome = 'activated'
    order by grant_row.parent_account_id
  loop
    perform private.enqueue_parent_access_invite(
      target_account_id,
      target_batch.id
    );
    invite_count := invite_count + 1;
  end loop;

  operation_result := jsonb_build_object(
    'operation', 'activate',
    'seasonId', p_season_id,
    'selectedCount', array_length(p_member_season_ids, 1),
    'changedCount', activated_count,
    'unchangedCount', unchanged_count,
    'groupCount', jsonb_array_length(preview->'groups'),
    'inviteJobCount', invite_count,
    'sessionsRevoked', 0,
    'committed', true,
    'reused', false
  );
  update private.parent_access_batches
  set result = operation_result,
      completed_at = now_utc
  where id = target_batch.id;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'parent.access.batch_activated',
    'parent_access_batch',
    target_batch.id,
    jsonb_build_object(
      'seasonId', p_season_id,
      'selectedCount', array_length(p_member_season_ids, 1),
      'changedCount', activated_count,
      'unchangedCount', unchanged_count,
      'inviteJobCount', invite_count
    ),
    p_correlation_id
  );
  return operation_result;
end;
$$;

create or replace function app.revoke_parent_portal_access(
  p_season_id uuid,
  p_grant_ids uuid[],
  p_reason text,
  p_expected_revision text,
  p_batch_key uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  normalized_reason text := nullif(trim(p_reason), '');
  request_hash text;
  preview jsonb;
  target_batch private.parent_access_batches%rowtype;
  target_grant private.parent_portal_grants%rowtype;
  account_id uuid;
  target_member_id uuid;
  now_utc timestamptz := timezone('utc', now());
  revoked_count integer := 0;
  unchanged_count integer := 0;
  sessions_revoked integer := 0;
  affected integer;
  operation_result jsonb;
begin
  if p_batch_key is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or normalized_reason is null
    or length(normalized_reason) not between 3 and 500
  then
    raise exception 'PARENT_ACCESS_COMMIT_INVALID' using errcode = '22023';
  end if;
  perform private.parent_revocation_preview(p_season_id, p_grant_ids);
  request_hash := encode(extensions.digest(jsonb_build_object(
    'operation', 'revoke',
    'seasonId', p_season_id,
    'grantIds', (
      select jsonb_agg(item order by item)
      from unnest(p_grant_ids) item
    ),
    'reason', normalized_reason,
    'expectedRevision', p_expected_revision
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-batch:' || p_batch_key::text, 0)
  );
  select * into target_batch
  from private.parent_access_batches batch
  where batch.batch_key = p_batch_key
  for update;
  if found then
    if target_batch.operation <> 'revoke'
      or target_batch.season_id <> p_season_id
      or target_batch.selection_hash <> request_hash
      or target_batch.actor_user_id <> actor
    then
      raise exception 'PARENT_ACCESS_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if target_batch.result is null then
      raise exception 'PARENT_ACCESS_BATCH_INCOMPLETE' using errcode = '40001';
    end if;
    return target_batch.result || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-grants-global', 0)
  );
  perform pg_advisory_xact_lock(
    hashtextextended('parent-access-season:' || p_season_id::text, 0)
  );
  perform 1
  from app.app_settings settings
  where settings.id = true
  for update;
  perform 1
  from app.member_seasons member_season
  join private.parent_portal_grants grant_row
    on grant_row.member_season_id = member_season.id
  where grant_row.id = any(p_grant_ids)
  order by member_season.id
  for update of member_season;
  perform 1
  from private.parent_portal_grants grant_row
  where grant_row.id = any(p_grant_ids)
  order by grant_row.id
  for update;

  preview := private.parent_revocation_preview(p_season_id, p_grant_ids);
  if preview->>'revision' <> p_expected_revision then
    raise exception 'PARENT_ACCESS_PREVIEW_STALE' using errcode = '40001';
  end if;
  if (preview->>'blockedCount')::integer > 0 then
    raise exception 'PARENT_ACCESS_SELECTION_BLOCKED' using errcode = '23514';
  end if;

  insert into private.parent_access_batches(
    batch_key,
    operation,
    season_id,
    selection_hash,
    selected_count,
    actor_user_id
  ) values (
    p_batch_key,
    'revoke',
    p_season_id,
    request_hash,
    array_length(p_grant_ids, 1),
    actor
  )
  returning * into target_batch;

  for target_grant in
    select grant_row.*
    from private.parent_portal_grants grant_row
    where grant_row.id = any(p_grant_ids)
    order by grant_row.id
    for update
  loop
    if target_grant.status = 'revoked' then
      insert into private.parent_access_batch_items(
        batch_id,
        member_season_id,
        grant_id,
        outcome
      ) values (
        target_batch.id,
        target_grant.member_season_id,
        target_grant.id,
        'unchanged'
      );
      unchanged_count := unchanged_count + 1;
      continue;
    end if;

    update private.parent_portal_grants
    set status = 'revoked',
        revoked_by = actor,
        revoked_at = now_utc,
        revoked_reason = normalized_reason,
        updated_at = now_utc
    where id = target_grant.id;
    select member_season.member_id into target_member_id
    from app.member_seasons member_season
    where member_season.id = target_grant.member_season_id;
    perform private.refresh_parent_legacy_projection(
      target_grant.parent_account_id,
      target_member_id
    );
    insert into private.parent_access_batch_items(
      batch_id,
      member_season_id,
      grant_id,
      outcome
    ) values (
      target_batch.id,
      target_grant.member_season_id,
      target_grant.id,
      'revoked'
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
      'parent.access.revoked',
      'parent_portal_grant',
      target_grant.id,
      jsonb_build_object(
        'memberSeasonId', target_grant.member_season_id,
        'seasonId', p_season_id,
        'batchId', target_batch.id,
        'reasonRecorded', true
      ),
      p_correlation_id
    );
    revoked_count := revoked_count + 1;
  end loop;

  for account_id in
    select distinct grant_row.parent_account_id
    from private.parent_access_batch_items batch_item
    join private.parent_portal_grants grant_row
      on grant_row.id = batch_item.grant_id
    where batch_item.batch_id = target_batch.id
      and grant_row.parent_account_id is not null
    order by grant_row.parent_account_id
  loop
    if not private.parent_account_has_portal_access(account_id) then
      update private.parent_sessions
      set revoked_at = now_utc
      where parent_account_id = account_id
        and revoked_at is null
        and expires_at > now_utc;
      get diagnostics affected = row_count;
      sessions_revoked := sessions_revoked + affected;
      update private.parent_otp_challenges
      set used_at = now_utc
      where parent_account_id = account_id
        and used_at is null
        and expires_at > now_utc;
    end if;
    update private.email_jobs invite_job
    set status = 'failed',
        completed_at = now_utc,
        last_error = 'access_revoked_before_send',
        updated_at = now_utc
    where invite_job.context_kind = 'portal_access'
      and invite_job.parent_account_id = account_id
      and invite_job.status in ('queued', 'retry')
      and not exists(
        select 1
        from private.parent_access_batch_items batch_item
        join private.parent_portal_grants batch_grant
          on batch_grant.id = batch_item.grant_id
        where batch_item.batch_id = invite_job.parent_access_batch_id
          and batch_grant.parent_account_id = account_id
          and batch_grant.status = 'active'
      );
  end loop;

  operation_result := jsonb_build_object(
    'operation', 'revoke',
    'seasonId', p_season_id,
    'selectedCount', array_length(p_grant_ids, 1),
    'changedCount', revoked_count,
    'unchangedCount', unchanged_count,
    'groupCount', jsonb_array_length(preview->'groups'),
    'inviteJobCount', 0,
    'sessionsRevoked', sessions_revoked,
    'committed', true,
    'reused', false
  );
  update private.parent_access_batches
  set result = operation_result,
      completed_at = now_utc
  where id = target_batch.id;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'parent.access.batch_revoked',
    'parent_access_batch',
    target_batch.id,
    jsonb_build_object(
      'seasonId', p_season_id,
      'selectedCount', array_length(p_grant_ids, 1),
      'changedCount', revoked_count,
      'unchangedCount', unchanged_count,
      'sessionsRevoked', sessions_revoked
    ),
    p_correlation_id
  );
  return operation_result;
end;
$$;

-- Keep the legacy members.active_for_season projection synchronized while the
-- authoritative participation state is season-bound. This prevents a status
-- change for the active season from accidentally affecting historical seasons.
create or replace function app.set_member_active_for_season(
  p_member_id uuid,
  p_active boolean,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_member app.members%rowtype;
  target_member_season app.member_seasons%rowtype;
  target_season_id uuid;
  normalized_reason text := trim(p_reason);
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_member_id is null
    or p_active is null
    or length(normalized_reason) not between 3 and 240
  then
    raise exception 'MEMBER_STATUS_INPUT_INVALID' using errcode = '22023';
  end if;

  select season.id into target_season_id
  from app.app_settings settings
  join app.seasons season
    on season.id = settings.active_season_id
    and season.status = 'open'
  where settings.id = true;
  if target_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;

  select * into target_member
  from app.members
  where id = p_member_id
  for update;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into target_member_season
  from app.member_seasons
  where member_id = p_member_id
    and season_id = target_season_id
  for update;
  if not found then
    raise exception 'MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  update app.member_seasons
  set participation_status =
        case when p_active then 'active'::app.member_season_status
             else 'inactive'::app.member_season_status end,
      updated_at = timezone('utc', now())
  where id = target_member_season.id;

  update app.members
  set active_for_season = p_active
  where id = p_member_id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  values(
    actor,
    case when p_active then 'member.activated' else 'member.deactivated' end,
    'member_season',
    target_member_season.id,
    jsonb_build_object(
      'memberId', p_member_id,
      'seasonId', target_season_id,
      'activeBefore', target_member_season.participation_status = 'active',
      'activeAfter', p_active,
      'reason', normalized_reason
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'memberId', p_member_id,
    'memberSeasonId', target_member_season.id,
    'seasonId', target_season_id,
    'activeForSeason', p_active
  );
end;
$$;

create or replace function private.consume_parent_otp(
  p_email text,
  p_code_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  account private.parent_accounts%rowtype;
  challenge private.parent_otp_challenges%rowtype;
  now_utc timestamptz := timezone('utc', now());
begin
  select * into account
  from private.parent_accounts
  where email_normalized = lower(trim(p_email))
  limit 1;
  if not found
    or not private.parent_account_has_portal_access(account.id)
  then
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into challenge
  from private.parent_otp_challenges
  where parent_account_id = account.id
  order by created_at desc
  limit 1
  for update;
  if not found
    or challenge.used_at is not null
    or challenge.expires_at <= now_utc
    or challenge.attempts >= challenge.max_attempts
  then
    return jsonb_build_object('status', 'invalid');
  end if;

  if challenge.code_hash <> p_code_hash then
    update private.parent_otp_challenges
    set attempts = attempts + 1
    where id = challenge.id;
    return jsonb_build_object('status', 'invalid');
  end if;

  update private.parent_otp_challenges
  set used_at = now_utc
  where id = challenge.id;
  update private.parent_accounts
  set last_login_at = now_utc
  where id = account.id;
  return jsonb_build_object(
    'status', 'verified',
    'parentAccountId', account.id
  );
end;
$$;

create or replace function public.create_parent_otp(
  p_email text,
  p_code_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
volatile
security definer
set search_path = private, app, extensions, pg_temp
as $$
declare
  account_id uuid;
  normalized_email text := lower(trim(p_email));
  email_key_hash text;
  now_utc timestamptz := timezone('utc', now());
begin
  if normalized_email is null
    or length(normalized_email) not between 3 and 254
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or p_code_hash is null
    or p_code_hash !~ '^[0-9a-f]{64}$'
    or p_expires_at is null
  then
    return null;
  end if;

  email_key_hash := encode(
    extensions.digest(normalized_email, 'sha256'),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('otp_request:' || email_key_hash, 0)
  );
  if exists(
    select 1
    from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '60 seconds'
  ) then
    return null;
  end if;
  if (
    select count(*)
    from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '1 hour'
  ) >= 5 then
    return null;
  end if;
  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values('otp_request', email_key_hash, now_utc);

  select account.id into account_id
  from private.parent_accounts account
  where account.email_normalized = normalized_email
    and private.parent_account_has_portal_access(account.id)
  for update;
  if account_id is null then
    return null;
  end if;

  update private.parent_otp_challenges
  set used_at = now_utc
  where parent_account_id = account_id
    and used_at is null
    and expires_at > now_utc;
  insert into private.parent_otp_challenges(
    parent_account_id,
    code_hash,
    expires_at
  ) values (
    account_id,
    p_code_hash,
    now_utc + interval '10 minutes'
  );
  return account_id;
end;
$$;

create or replace function public.create_parent_session(
  p_parent_account_id uuid,
  p_token_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  session_id uuid;
begin
  if p_parent_account_id is null
    or p_token_hash is null
    or p_token_hash !~ '^[0-9a-f]{64}$'
    or p_expires_at is null
    or p_expires_at <= timezone('utc', now())
    or p_expires_at > timezone('utc', now()) + interval '30 days'
  then
    raise exception 'PARENT_SESSION_INVALID' using errcode = '22023';
  end if;
  if not private.parent_account_has_portal_access(p_parent_account_id) then
    raise exception 'PARENT_ACCESS_REQUIRED' using errcode = '42501';
  end if;
  insert into private.parent_sessions(
    parent_account_id,
    token_hash,
    expires_at
  ) values (
    p_parent_account_id,
    p_token_hash,
    p_expires_at
  )
  returning id into session_id;
  return session_id;
end;
$$;

create or replace function public.get_parent_session(p_token_hash text)
returns table (
  parent_account_id uuid,
  email_normalized text
)
language plpgsql
volatile
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_account private.parent_accounts%rowtype;
  now_utc timestamptz := timezone('utc', now());
begin
  select account.* into target_account
  from private.parent_sessions session
  join private.parent_accounts account
    on account.id = session.parent_account_id
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > now_utc
    and private.parent_account_has_portal_access(account.id)
  limit 1;
  if not found then
    return;
  end if;

  update private.parent_sessions session
  set last_seen_at = now_utc
  where session.token_hash = p_token_hash
    and session.last_seen_at < now_utc - interval '5 minutes';

  return query
  select target_account.id, target_account.email_normalized;
end;
$$;

drop function if exists public.get_parent_members(text);
create function public.get_parent_members(p_token_hash text)
returns table (
  member_id uuid,
  member_season_id uuid,
  relation_number text,
  first_name text,
  insertion text,
  last_name text,
  team text,
  order_id uuid,
  amount_due_cents integer,
  payment_status text,
  order_status text,
  article_lines jsonb,
  qr_version integer,
  date_of_birth date,
  gender text,
  season_id uuid,
  season_name text
)
language sql
security definer
set search_path = private, app, pg_temp
as $$
  select member.id,
    member_season.id,
    member.relation_number,
    member.first_name,
    member.insertion,
    member.last_name,
    member_season.team_name,
    orders.id,
    orders.amount_due_cents,
    coalesce((
      select payment.status::text
      from app.payments payment
      where payment.order_id = orders.id
      order by case payment.status
        when 'paid' then 1
        when 'refunded' then 2
        when 'duplicate_paid' then 3
        else 4
      end, payment.created_at desc
      limit 1
    ), 'open'),
    orders.order_status,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line.id,
        'article', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', line.status::text
      ) order by article.sort_order, line.size_snapshot, line.id)
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = orders.id
        and line.status <> 'cancelled'
    ), '[]'::jsonb),
    (
      select token.version
      from private.qr_tokens token
      where token.order_id = orders.id and token.active = true
      limit 1
    ),
    identity.date_of_birth,
    member.gender::text,
    member_season.season_id,
    season.name
  from private.parent_sessions session
  join private.parent_accounts account
    on account.id = session.parent_account_id
  join lateral private.parent_authorized_member_seasons(
    session.parent_account_id
  ) authorized on true
  join app.member_seasons member_season
    on member_season.id = authorized.member_season_id
  join app.members member on member.id = member_season.member_id
  join app.seasons season on season.id = member_season.season_id
  left join private.member_sensitive_identity identity
    on identity.member_id = member.id
  left join app.member_orders orders
    on orders.member_season_id = member_season.id
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
  order by season.starts_on desc nulls last,
    lower(member.last_name),
    lower(member.first_name),
    member_season.id;
$$;

create or replace function public.prepare_mollie_payment(
  p_token_hash text,
  p_order_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  target_payment app.payments%rowtype;
  now_utc timestamptz := timezone('utc', now());
  reused boolean := false;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$'
    or length(trim(p_idempotency_key)) not between 8 and 160
  then
    raise exception 'INVALID_PAYMENT_REQUEST' using errcode = '22023';
  end if;
  select orders.* into target_order
  from private.parent_sessions session
  join lateral private.parent_authorized_member_seasons(
    session.parent_account_id
  ) authorized on true
  join app.member_seasons member_season
    on member_season.id = authorized.member_season_id
  join app.member_orders orders
    on orders.member_season_id = member_season.id
  join app.app_settings settings
    on settings.id = true
    and settings.active_season_id = orders.season_id
  join app.seasons season
    on season.id = orders.season_id
    and season.status = 'open'
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > now_utc
    and orders.id = p_order_id
  for update of orders;
  if not found then
    raise exception 'PARENT_ORDER_ACCESS_DENIED' using errcode = '42501';
  end if;
  if exists(
    select 1 from app.payments
    where order_id = p_order_id and status = 'paid'
  ) then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23514';
  end if;

  select * into target_payment
  from app.payments payment
  where payment.idempotency_key = trim(p_idempotency_key)
  for update;
  if found then
    if target_payment.order_id <> p_order_id then
      raise exception 'PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if target_payment.status not in ('open', 'pending') then
      raise exception 'PAYMENT_ATTEMPT_NOT_REUSABLE' using errcode = '23514';
    end if;
    if (
      target_payment.provider_payment_id is null
      and target_payment.created_at + interval '1 hour' <= now_utc
    ) or (
      target_payment.provider_payment_id is not null
      and (
        target_payment.checkout_url is null
        or target_payment.provider_expires_at <= now_utc
      )
    ) then
      raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
    end if;
    reused := true;
  else
    select * into target_payment
    from app.payments payment
    where payment.order_id = p_order_id
      and payment.method = 'mollie'
      and payment.status in ('open', 'pending')
    order by payment.created_at desc
    limit 1
    for update;
    if found then
      if (
        target_payment.provider_payment_id is null
        and target_payment.created_at + interval '1 hour' <= now_utc
      ) or (
        target_payment.provider_payment_id is not null
        and (
          target_payment.checkout_url is null
          or target_payment.provider_expires_at <= now_utc
        )
      ) then
        raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514';
      end if;
      reused := true;
    else
      insert into app.payments(
        order_id,
        method,
        status,
        amount_cents,
        currency,
        idempotency_key
      ) values (
        p_order_id,
        'mollie',
        'open',
        target_order.amount_due_cents,
        'EUR',
        trim(p_idempotency_key)
      )
      returning * into target_payment;
    end if;
  end if;

  return jsonb_build_object(
    'paymentId', target_payment.id,
    'orderId', target_order.id,
    'amountCents', target_order.amount_due_cents,
    'currency', 'EUR',
    'status', target_payment.status::text,
    'providerPaymentId', target_payment.provider_payment_id,
    'checkoutUrl', target_payment.checkout_url,
    'reused', reused,
    'idempotencyKey', target_payment.idempotency_key,
    'metadata', jsonb_build_object(
      'payment_id', target_payment.id,
      'order_id', target_order.id,
      'member_id', target_order.member_id,
      'member_season_id', target_order.member_season_id,
      'season_id', target_order.season_id,
      'schema_version', 2
    )
  );
end;
$$;

revoke all on function app.get_parent_access_cutover_status()
  from public, anon, authenticated;
revoke all on function app.enable_parent_access_grants_v2(text, uuid)
  from public, anon, authenticated;
revoke all on function app.get_parent_access_workspace(uuid, text, integer, integer)
  from public, anon, authenticated;
revoke all on function app.preview_parent_portal_activation(uuid, uuid[])
  from public, anon, authenticated;
revoke all on function app.preview_parent_portal_revocation(uuid, uuid[])
  from public, anon, authenticated;
revoke all on function app.activate_parent_portal_access(uuid, uuid[], text, uuid, uuid)
  from public, anon, authenticated;
revoke all on function app.revoke_parent_portal_access(uuid, uuid[], text, text, uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.get_parent_access_cutover_status()
  to authenticated;
grant execute on function app.enable_parent_access_grants_v2(text, uuid)
  to authenticated;
grant execute on function app.get_parent_access_workspace(uuid, text, integer, integer)
  to authenticated;
grant execute on function app.preview_parent_portal_activation(uuid, uuid[])
  to authenticated;
grant execute on function app.preview_parent_portal_revocation(uuid, uuid[])
  to authenticated;
grant execute on function app.activate_parent_portal_access(uuid, uuid[], text, uuid, uuid)
  to authenticated;
grant execute on function app.revoke_parent_portal_access(uuid, uuid[], text, text, uuid, uuid)
  to authenticated;

revoke all on function private.consume_parent_otp(text, text)
  from public, anon, authenticated;
grant execute on function private.consume_parent_otp(text, text)
  to service_role;
revoke all on function public.create_parent_otp(text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.create_parent_otp(text, text, timestamptz)
  to service_role;
revoke all on function public.create_parent_session(uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.create_parent_session(uuid, text, timestamptz)
  to service_role;
revoke all on function public.get_parent_session(text)
  from public, anon, authenticated;
grant execute on function public.get_parent_session(text)
  to service_role;
revoke all on function public.get_parent_members(text)
  from public, anon, authenticated;
grant execute on function public.get_parent_members(text)
  to service_role;
revoke all on function public.prepare_mollie_payment(text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.prepare_mollie_payment(text, uuid, text)
  to service_role;

-- Preserve the six-template rollback contract while the v2 mail workspace is
-- still used by the current application.
create or replace function app.get_email_workspace_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  role app.staff_role := app.staff_role();
  legacy_template_keys constant text[] := array[
    'verification_code',
    'payment_request',
    'payment_received',
    'ready_for_pickup',
    'payment_reminder',
    'qr_code_resent'
  ];
begin
  if role not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'recoveryAllowed', role = 'beheerder',
    'templateKeys', legacy_template_keys,
    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', template.id,
        'key', template.template_key,
        'subjectSource', template.subject_source,
        'bodySource', template.body_source,
        'allowedShortcodes', template.allowed_shortcodes,
        'active', template.active,
        'version', template.version,
        'updatedAt', template.updated_at
      ) order by template.template_key)
      from app.email_templates template
      where template.template_key = any(legacy_template_keys)
    ), '[]'::jsonb),
    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', batch.id,
        'batchKey', batch.batch_key,
        'templateKey', template.template_key,
        'selectedCount', batch.selected_count,
        'createdAt', batch.created_at
      ) order by batch.created_at desc)
      from (
        select email_batch.*
        from app.email_batches email_batch
        join app.email_templates batch_template
          on batch_template.id = email_batch.template_id
        where batch_template.template_key = any(legacy_template_keys)
        order by email_batch.created_at desc
        limit 25
      ) batch
      join app.email_templates template on template.id = batch.template_id
    ), '[]'::jsonb),
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', job.id,
        'orderId', job.order_id,
        'templateKey', job.template_key,
        'status', job.status,
        'attempts', job.attempts,
        'deliveryStatus', job.delivery_status,
        'availableAt', job.available_at,
        'sentAt', job.sent_at,
        'createdAt', job.created_at,
        'updatedAt', job.updated_at,
        'claimedAt', job.claimed_at,
        'recoverable', role = 'beheerder' and (
          job.status = 'delivery_uncertain'
          or (
            job.status = 'processing'
            and job.claimed_at < timezone('utc', now()) - interval '15 minutes'
          )
        )
      ) order by job.created_at desc)
      from (
        select *
        from private.email_jobs
        where context_kind = 'order' and order_id is not null
        order by created_at desc
        limit 100
      ) job
    ), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderId', orders.id,
        'memberName', concat_ws(
          ' ',
          member.first_name,
          member.insertion,
          member.last_name
        ),
        'relationNumber', member.relation_number,
        'team', member.team,
        'season', season.name,
        'amountDueCents', orders.amount_due_cents,
        'paymentReminderEligible', not exists(
          select 1
          from app.payments payment
          where payment.order_id = orders.id and payment.status = 'paid'
        ),
        'readyForPickupEligible', exists(
          select 1
          from app.payments payment
          where payment.order_id = orders.id and payment.status = 'paid'
        ) and exists(
          select 1
          from app.order_lines line
          where line.order_id = orders.id
            and line.status = 'ready_for_pickup'
        ),
        'lines', coalesce((
          select jsonb_agg(jsonb_build_object(
            'orderLineId', line.id,
            'article', article.name,
            'size', line.size_snapshot,
            'quantity', line.quantity,
            'status', line.status::text
          ) order by article.sort_order, line.id)
          from app.order_lines line
          join app.articles article on article.id = line.article_id
          where line.order_id = orders.id and line.status <> 'cancelled'
        ), '[]'::jsonb)
      ) order by member.last_name, member.first_name)
      from app.member_orders orders
      join app.members member
        on member.id = orders.member_id
        and member.active_for_season
      join app.seasons season on season.id = orders.season_id
      join app.app_settings settings
        on settings.id = true
        and settings.active_season_id = orders.season_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.get_email_workspace_v3()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_role app.staff_role := app.staff_role();
  legacy_template_keys constant text[] := array[
    'verification_code',
    'payment_request',
    'payment_received',
    'ready_for_pickup',
    'payment_reminder',
    'qr_code_resent'
  ];
  visible_template_keys text[];
  result jsonb;
begin
  if target_role not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  visible_template_keys := case
    when target_role = 'beheerder'
      then legacy_template_keys || array['portal_access_invite']
    else legacy_template_keys
  end;

  result := app.get_email_workspace_v2();
  result := jsonb_set(
    result,
    '{templateKeys}',
    to_jsonb(visible_template_keys),
    true
  );
  result := jsonb_set(
    result,
    '{templates}',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', template.id,
        'key', template.template_key,
        'subjectSource', template.subject_source,
        'bodySource', template.body_source,
        'allowedShortcodes', template.allowed_shortcodes,
        'active', template.active,
        'version', template.version,
        'updatedAt', template.updated_at
      ) order by array_position(visible_template_keys, template.template_key))
      from app.email_templates template
      where template.template_key = any(visible_template_keys)
    ), '[]'::jsonb),
    true
  );
  result := jsonb_set(
    result,
    '{jobs}',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', job.id,
        'contextKind', job.context_kind,
        'orderId', job.order_id,
        'templateKey', job.template_key,
        'status', job.status,
        'attempts', job.attempts,
        'deliveryStatus', job.delivery_status,
        'availableAt', job.available_at,
        'sentAt', job.sent_at,
        'createdAt', job.created_at,
        'updatedAt', job.updated_at,
        'claimedAt', job.claimed_at,
        'recoverable', target_role = 'beheerder' and (
          job.status = 'delivery_uncertain'
          or (
            job.status = 'processing'
            and job.claimed_at < timezone('utc', now()) - interval '15 minutes'
          )
        )
      ) order by job.created_at desc)
      from (
        select email_job.*
        from private.email_jobs email_job
        where email_job.context_kind = 'order'
          or target_role = 'beheerder'
        order by email_job.created_at desc
        limit 100
      ) job
    ), '[]'::jsonb),
    true
  );
  return result;
end;
$$;

revoke all on function app.get_email_workspace_v3()
  from public, anon, authenticated;
grant execute on function app.get_email_workspace_v3()
  to authenticated;

create or replace function app.update_email_template(
  p_template_id uuid,
  p_subject_source text,
  p_body_source text,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_key text;
begin
  select template.template_key into target_key
  from app.email_templates template
  where template.id = p_template_id;
  if target_key is null then
    raise exception 'EMAIL_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_key = 'verification_code'
    and strpos(
      p_subject_source || E'\n' || p_body_source,
      '{{verificatiecode}}'
    ) = 0
  then
    raise exception 'EMAIL_VERIFICATION_CODE_REQUIRED' using errcode = '23514';
  end if;
  if target_key = 'portal_access_invite' then
    perform private.require_admin_aal2();
    if strpos(
      p_subject_source || E'\n' || p_body_source,
      '{{portaal_url}}'
    ) = 0 then
      raise exception 'EMAIL_PORTAL_URL_REQUIRED' using errcode = '23514';
    end if;
  end if;
  return app.update_email_template_core_v2(
    p_template_id,
    p_subject_source,
    p_body_source,
    p_expected_version
  );
end;
$$;

revoke all on function app.update_email_template(uuid, text, text, integer)
  from public, anon, authenticated, service_role;
grant execute on function app.update_email_template(uuid, text, text, integer)
  to authenticated;
