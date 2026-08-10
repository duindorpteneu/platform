-- Audited administrator controls for the remaining Phase-B release gates.
-- Specialized parent-access, allocation/QR and mail gates remain authoritative.

create or replace function private.release_feature_base_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  with metrics as (
    select
      coalesce((
        select flag.enabled
        from app.release_feature_flags flag
        where flag.key = 'member_seasons_v2'
      ), false) member_seasons_enabled,
      coalesce((
        select flag.enabled
        from app.release_feature_flags flag
        where flag.key = 'package_orders_v2'
      ), false) package_orders_enabled,
      coalesce((
        select flag.enabled
        from app.release_feature_flags flag
        where flag.key = 'dynamic_import_v2'
      ), false) dynamic_import_enabled,
      (
        select count(*)::integer
        from app.member_seasons member_season
        where member_season.reconciliation_status = 'legacy_unknown'
      ) unresolved_member_seasons,
      (
        select count(*)::integer
        from app.member_orders orders
        where orders.active_package_snapshot_id is null
      ) legacy_orders_without_package_snapshot
  ),
  payload as (
    select jsonb_build_object(
      'memberSeasons', jsonb_build_object(
        'enabled', metrics.member_seasons_enabled,
        'ready', metrics.unresolved_member_seasons = 0,
        'blockerCount', metrics.unresolved_member_seasons
      ),
      'packageOrders', jsonb_build_object(
        'enabled', metrics.package_orders_enabled,
        'ready', metrics.member_seasons_enabled
          and metrics.legacy_orders_without_package_snapshot = 0,
        'blockerCount', metrics.legacy_orders_without_package_snapshot,
        'dependencyReady', metrics.member_seasons_enabled
      ),
      'dynamicImport', jsonb_build_object(
        'enabled', metrics.dynamic_import_enabled,
        'ready', metrics.member_seasons_enabled,
        'blockerCount', case
          when metrics.member_seasons_enabled then 0
          else 1
        end,
        'cutoverActive', exists(
          select 1
          from private.release_cutovers cutover
          where cutover.key = 'dynamic_import_v2'
        )
      )
    ) value
    from metrics
  )
  select payload.value || jsonb_build_object(
    'revision',
    encode(extensions.digest(payload.value::text, 'sha256'), 'hex')
  )
  from payload;
$$;

revoke all on function private.release_feature_base_snapshot()
from public, anon, authenticated, service_role;

create or replace function app.get_release_feature_controls_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  flags jsonb;
begin
  perform private.require_admin_aal2();
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'key', flag.key,
      'enabled', flag.enabled,
      'description', flag.description,
      'updatedAt', flag.updated_at
    )
    order by flag.key
  ), '[]'::jsonb)
  into flags
  from app.release_feature_flags flag;
  return private.release_feature_base_snapshot()
    || jsonb_build_object('flags', flags);
end;
$$;

create or replace function app.activate_release_feature_v1(
  p_key text,
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
  ready boolean;
  already_enabled boolean;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_key not in (
    'member_seasons_v2',
    'package_orders_v2',
    'dynamic_import_v2'
  )
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'RELEASE_FEATURE_INPUT_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('release-feature-controls-v1', 0)
  );
  lock table app.release_feature_flags in share row exclusive mode;
  lock table app.member_seasons in share mode;
  lock table app.member_orders in share mode;
  snapshot := private.release_feature_base_snapshot();
  if snapshot->>'revision' <> p_expected_revision then
    raise exception 'RELEASE_FEATURE_STALE' using errcode = '40001';
  end if;
  already_enabled := case p_key
    when 'member_seasons_v2'
      then (snapshot #>> '{memberSeasons,enabled}')::boolean
    when 'package_orders_v2'
      then (snapshot #>> '{packageOrders,enabled}')::boolean
    else (snapshot #>> '{dynamicImport,enabled}')::boolean
  end;
  if already_enabled then
    return app.get_release_feature_controls_v1()
      || jsonb_build_object('reused', true);
  end if;
  ready := case p_key
    when 'member_seasons_v2'
      then (snapshot #>> '{memberSeasons,ready}')::boolean
    when 'package_orders_v2'
      then (snapshot #>> '{packageOrders,ready}')::boolean
    else (snapshot #>> '{dynamicImport,ready}')::boolean
  end;
  if not ready then
    raise exception 'RELEASE_FEATURE_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;

  if p_key = 'dynamic_import_v2' then
    insert into private.release_cutovers(key)
    values(p_key)
    on conflict (key) do nothing;
  end if;
  update app.release_feature_flags
  set enabled = true,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key = p_key;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata,
    correlation_id
  ) values (
    actor,
    'release.feature.activated',
    'release_feature_flag',
    jsonb_build_object(
      'key', p_key,
      'reason', normalized_reason,
      'preflightRevision', p_expected_revision
    ),
    p_correlation_id
  );
  return app.get_release_feature_controls_v1()
    || jsonb_build_object('reused', false);
end;
$$;

create or replace function app.pause_release_feature_v1(
  p_key text,
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
  normalized_reason text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_key <> 'dynamic_import_v2'
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'RELEASE_FEATURE_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('release-feature-controls-v1', 0)
  );
  update app.release_feature_flags
  set enabled = false,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key = p_key;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata,
    correlation_id
  ) values (
    actor,
    'release.feature.paused',
    'release_feature_flag',
    jsonb_build_object(
      'key', p_key,
      'reason', normalized_reason,
      'cutoverRemainsActive', true
    ),
    p_correlation_id
  );
  return app.get_release_feature_controls_v1();
end;
$$;

revoke all on function app.get_release_feature_controls_v1()
from public, anon;
revoke all on function app.activate_release_feature_v1(
  text, text, text, uuid
) from public, anon;
revoke all on function app.pause_release_feature_v1(
  text, text, uuid
) from public, anon;
grant execute on function app.get_release_feature_controls_v1()
to authenticated;
grant execute on function app.activate_release_feature_v1(
  text, text, text, uuid
) to authenticated;
grant execute on function app.pause_release_feature_v1(
  text, text, uuid
) to authenticated;

comment on function app.get_release_feature_controls_v1()
is 'AAL2 beheerder-only PII-free preflight for Phase-B release controls.';
comment on function app.activate_release_feature_v1(
  text, text, text, uuid
) is 'AAL2 beheerder-only audited activation with stale-preflight fencing.';
comment on function app.pause_release_feature_v1(
  text, text, uuid
) is 'AAL2 beheerder-only operational pause for dynamic import; cutover remains immutable.';

notify pgrst, 'reload schema';
