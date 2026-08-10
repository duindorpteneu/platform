-- Staff package selection is a browser mutation. Keep a durable result per
-- request id so a lost success response can be retried without repeating the
-- mutation or requiring the now-stale workspace revision.
create table private.staff_package_selection_requests (
  request_id uuid primary key,
  staff_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  package_revision_id uuid not null
    references app.package_template_revisions(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
  ),
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

alter table private.staff_package_selection_requests enable row level security;
revoke all on table private.staff_package_selection_requests
from public, anon, authenticated, service_role;

create or replace function private.protect_staff_package_selection_request()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'STAFF_PACKAGE_SELECTION_REQUEST_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger staff_package_selection_requests_immutable
before update or delete on private.staff_package_selection_requests
for each row execute function private.protect_staff_package_selection_request();

create or replace function app.select_member_package_v3(
  p_member_season_id uuid,
  p_package_revision_id uuid,
  p_expected_revision text,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  existing private.staff_package_selection_requests%rowtype;
  computed_hash text;
  result jsonb;
  stable_result jsonb;
begin
  if p_request_id is null then
    raise exception 'PACKAGE_SELECTION_REQUEST_INVALID' using errcode = '22023';
  end if;

  computed_hash := encode(extensions.digest(
    jsonb_build_object(
      'memberSeasonId', p_member_season_id,
      'packageRevisionId', p_package_revision_id,
      'revision', p_expected_revision,
      'reason', btrim(coalesce(p_reason, ''))
    )::text,
    'sha256'
  ), 'hex');

  perform pg_advisory_xact_lock(
    hashtextextended(
      'staff-package-selection-request:' || p_request_id::text,
      0
    )
  );
  select *
  into existing
  from private.staff_package_selection_requests request
  where request.request_id = p_request_id
  for update;
  if found then
    if existing.staff_user_id <> actor
      or existing.request_hash <> computed_hash
    then
      raise exception 'PACKAGE_SELECTION_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;

  result := app.select_member_package_v2(
    p_member_season_id,
    p_package_revision_id,
    p_expected_revision,
    btrim(p_reason),
    p_correlation_id
  );
  stable_result := result || jsonb_build_object('reused', false);

  insert into private.staff_package_selection_requests(
    request_id,
    staff_user_id,
    member_season_id,
    package_revision_id,
    request_hash,
    result_snapshot,
    correlation_id
  )
  values(
    p_request_id,
    actor,
    p_member_season_id,
    p_package_revision_id,
    computed_hash,
    stable_result,
    p_correlation_id
  );
  return stable_result;
end;
$$;

revoke execute on function app.select_member_package_v2(
  uuid, uuid, text, text, uuid
) from authenticated;
revoke all on function app.select_member_package_v3(
  uuid, uuid, text, text, uuid, uuid
) from public, anon;
grant execute on function app.select_member_package_v3(
  uuid, uuid, text, text, uuid, uuid
) to authenticated;

-- The existing package audit already records actor, snapshots and correlation;
-- persist the mandatory operator reason as well.
do $migration$
declare
  function_source text;
  needle text := $needle$
      'packagePriceCents', revision.price_cents,
      'source', case when p_parent_account_id is null then 'staff' else 'parent' end
$needle$;
  replacement text := $replacement$
      'packagePriceCents', revision.price_cents,
      'source', case when p_parent_account_id is null then 'staff' else 'parent' end,
      'reason', p_reason
$replacement$;
begin
  function_source := pg_get_functiondef(
    'private.apply_member_package_selection(uuid,uuid,text,uuid,uuid,text,uuid)'::regprocedure
  );
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SELECTION_REASON_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

revoke all on function private.protect_staff_package_selection_request()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
