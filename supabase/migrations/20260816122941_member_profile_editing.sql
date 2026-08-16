-- Administrator-controlled member profile editing and journal-aware staff
-- size corrections. Old and new profile values are not copied into audit
-- metadata; parent access grants remain an explicitly managed concern.

drop policy if exists "operations can manage members" on app.members;
drop policy if exists "clothing staff can read members" on app.members;
create policy "clothing staff can read members" on app.members
for select
using (app.staff_role() in ('beheerder', 'kledingcommissie'));
revoke insert, update, delete on table app.members from authenticated;
grant select on table app.members to authenticated;

create table private.member_profile_edit_requests (
  request_id uuid primary key,
  staff_user_id uuid not null,
  member_id uuid not null references app.members(id) on delete restrict,
  member_season_id uuid not null references app.member_seasons(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null,
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

create table private.member_size_edit_requests (
  request_id uuid primary key,
  staff_user_id uuid not null,
  member_id uuid not null references app.members(id) on delete restrict,
  member_season_id uuid not null references app.member_seasons(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null,
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

alter table private.member_profile_edit_requests enable row level security;
alter table private.member_size_edit_requests enable row level security;
revoke all on table private.member_profile_edit_requests
from public, anon, authenticated, service_role;
revoke all on table private.member_size_edit_requests
from public, anon, authenticated, service_role;

create or replace function private.reject_member_edit_request_mutation()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'MEMBER_EDIT_REQUEST_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger member_profile_edit_requests_immutable
before update or delete on private.member_profile_edit_requests
for each row execute function private.reject_member_edit_request_mutation();
create trigger member_size_edit_requests_immutable
before update or delete on private.member_size_edit_requests
for each row execute function private.reject_member_edit_request_mutation();

revoke all on function private.reject_member_edit_request_mutation()
from public, anon, authenticated, service_role;

create or replace function private.member_profile_revision(
  p_member_id uuid,
  p_member_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(convert_to(concat_ws('|',
    'member-profile-v1',
    member.id::text,
    member_season.id::text,
    member.first_name,
    coalesce(member.insertion, ''),
    member.last_name,
    coalesce(member.email, ''),
    member.gender::text,
    coalesce(identity.date_of_birth::text, ''),
    coalesce(member_season.team_name, ''),
    member_season.participation_status::text,
    member_season.reconciliation_status::text,
    member.updated_at::text,
    member_season.updated_at::text,
    identity.updated_at::text
  ), 'UTF8'), 'sha256'), 'hex')
  from app.members member
  join app.member_seasons member_season
    on member_season.id = p_member_season_id
    and member_season.member_id = member.id
  join private.member_sensitive_identity identity
    on identity.member_id = member.id
  where member.id = p_member_id;
$$;

revoke all on function private.member_profile_revision(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.member_size_profile_json_v3(
  p_member_season_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with profile as (
    select private.member_size_profile_json_v2(p_member_season_id) result
  ), expanded as (
    select
      profile.result,
      article.value,
      article.ordinality,
      line.id order_line_id,
      size_profile.selection_status,
      size_profile.selection_source,
      size_profile.raw_value,
      size_profile.member_note,
      size_profile.requested_raw_value,
      size_profile.requested_member_note,
      exists(
        select 1 from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status = 'reserved'
      ) or exists(
        select 1 from app.inventory_reservations reservation
        where reservation.order_line_id = line.id
          and reservation.status = 'reserved'
      ) has_reservation,
      coalesce(line.status = 'picked_up', false)
        or exists(
          select 1 from app.inventory_allocations allocation
          where allocation.order_line_id = line.id
            and allocation.status = 'fulfilled'
        )
        or exists(
          select 1 from app.inventory_reservations reservation
          where reservation.order_line_id = line.id
            and reservation.status = 'fulfilled'
        )
        or exists(
          select 1 from app.fulfilment_lines fulfilment_line
          where fulfilment_line.order_line_id = line.id
            and fulfilment_line.reversed_at is null
        ) issued
    from profile
    cross join lateral jsonb_array_elements(profile.result->'articles')
      with ordinality article(value, ordinality)
    join app.member_seasons member_season
      on member_season.id = p_member_season_id
    left join app.member_article_sizes size_profile
      on size_profile.member_season_id = member_season.id
      and size_profile.article_id = (article.value->>'id')::uuid
    left join lateral (
      select order_line.id, order_line.status
      from app.member_orders orders
      join app.order_lines order_line on order_line.order_id = orders.id
      where orders.member_season_id = member_season.id
        and order_line.article_id = (article.value->>'id')::uuid
        and order_line.status <> 'cancelled'
      order by order_line.created_at desc, order_line.id desc
      limit 1
    ) line on true
  )
  select jsonb_set(
    profile.result,
    '{articles}',
    coalesce((
      select jsonb_agg(
        expanded.value || jsonb_build_object(
          'orderLineId', expanded.order_line_id,
          'selectionStatus', coalesce(expanded.selection_status::text, 'missing'),
          'selectionSource', expanded.selection_source::text,
          'rawValue', expanded.raw_value,
          'memberNote', expanded.member_note,
          'requestedRawValue', expanded.requested_raw_value,
          'requestedMemberNote', expanded.requested_member_note,
          'hasReservation', expanded.has_reservation,
          'issued', expanded.issued,
          'editable', (profile.result->>'editable')::boolean
            and coalesce((expanded.value->>'active')::boolean, false)
            and not expanded.issued
            and (
              not expanded.has_reservation
              or app.staff_role() = 'beheerder'
            ),
          'editBlockReason', case
            when not (profile.result->>'editable')::boolean then 'season_locked'
            when not coalesce((expanded.value->>'active')::boolean, false) then 'article_inactive'
            when expanded.issued then 'issued'
            when expanded.has_reservation and app.staff_role() <> 'beheerder' then 'reserved_admin_required'
            else null
          end
        ) order by expanded.ordinality
      ) from expanded
    ), '[]'::jsonb),
    true
  ) || jsonb_build_object('memberSeasonId', p_member_season_id)
  from profile;
$$;

create or replace function private.member_size_profile_json(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_season_id uuid;
begin
  select member_season.id into target_member_season_id
  from app.app_settings settings
  join app.member_seasons member_season
    on member_season.season_id = settings.active_season_id
    and member_season.member_id = p_member_id
  where settings.id = true;
  if target_member_season_id is null then
    if not exists(select 1 from app.members member where member.id = p_member_id) then
      raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
    end if;
    return null;
  end if;
  return private.member_size_profile_json_v3(target_member_season_id);
end;
$$;

create or replace function app.get_member_detail_v6(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  target_member_season_id uuid;
begin
  perform private.require_clothing_aal2();
  result := app.get_member_detail_v5(p_member_id);
  select member_season.id into target_member_season_id
  from app.app_settings settings
  join app.member_seasons member_season
    on member_season.season_id = settings.active_season_id
    and member_season.member_id = p_member_id
  where settings.id = true;
  if target_member_season_id is null then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;
  return jsonb_set(
    result,
    '{sizeProfile}',
    private.member_size_profile_json_v3(target_member_season_id),
    true
  ) || jsonb_build_object(
    'memberSeasonId', target_member_season_id,
    'profileRevision', private.member_profile_revision(
      p_member_id,
      target_member_season_id
    )
  );
end;
$$;

create or replace function app.update_member_profile_v1(
  p_member_id uuid,
  p_member_season_id uuid,
  p_first_name text,
  p_insertion text,
  p_last_name text,
  p_email text,
  p_date_of_birth date,
  p_gender app.gender_code,
  p_team text,
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
#variable_conflict use_variable
declare
  actor uuid := private.require_admin_aal2();
  first_name text := nullif(btrim(regexp_replace(normalize(p_first_name, NFKC), '[[:space:]]+', ' ', 'g')), '');
  insertion text := nullif(btrim(regexp_replace(normalize(p_insertion, NFKC), '[[:space:]]+', ' ', 'g')), '');
  last_name text := nullif(btrim(regexp_replace(normalize(p_last_name, NFKC), '[[:space:]]+', ' ', 'g')), '');
  email text := lower(nullif(btrim(normalize(p_email, NFKC)), ''));
  team text := nullif(btrim(regexp_replace(normalize(p_team, NFKC), '[[:space:]]+', ' ', 'g')), '');
  reason text := nullif(btrim(regexp_replace(normalize(p_reason, NFKC), '[[:space:]]+', ' ', 'g')), '');
  request_hash text;
  previous private.member_profile_edit_requests%rowtype;
  target_member app.members%rowtype;
  target_member_season app.member_seasons%rowtype;
  target_identity private.member_sensitive_identity%rowtype;
  active_season_id uuid;
  changed_fields text[] := array[]::text[];
  result jsonb;
begin
  if p_member_id is null or p_member_season_id is null or p_request_id is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or first_name is null or length(first_name) > 120
    or last_name is null or length(last_name) > 120
    or length(coalesce(insertion, '')) > 80
    or length(coalesce(email, '')) > 320
    or length(coalesce(team, '')) > 120
    or length(coalesce(reason, '')) not between 3 and 500
    or concat_ws('', first_name, insertion, last_name, email, team) ~ '[[:cntrl:]]'
    or (email is not null and email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
    or (p_date_of_birth is not null and p_date_of_birth not between date '1900-01-01' and current_date)
  then
    raise exception 'MEMBER_PROFILE_INPUT_INVALID' using errcode = '22023';
  end if;

  request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'memberId', p_member_id,
    'memberSeasonId', p_member_season_id,
    'firstName', first_name,
    'insertion', insertion,
    'lastName', last_name,
    'email', email,
    'dateOfBirth', p_date_of_birth,
    'gender', p_gender::text,
    'team', team,
    'expectedRevision', p_expected_revision,
    'reason', reason
  )::text, 'UTF8'), 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    'member-profile-request:' || p_request_id::text, 0
  ));
  select * into previous from private.member_profile_edit_requests request
  where request.request_id = p_request_id;
  if found then
    if previous.staff_user_id <> actor or previous.request_hash <> request_hash then
      raise exception 'MEMBER_PROFILE_REQUEST_REUSED' using errcode = '40001';
    end if;
    return previous.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'dynamic-import-member:' || p_member_id::text, 0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'dynamic-import-member-season:' || p_member_season_id::text, 0
  ));

  select settings.active_season_id into active_season_id
  from app.app_settings settings where settings.id = true;
  select * into target_member from app.members member
  where member.id = p_member_id for update;
  select * into target_member_season from app.member_seasons member_season
  where member_season.id = p_member_season_id
    and member_season.member_id = p_member_id
    and member_season.season_id = active_season_id
  for update;
  select * into target_identity from private.member_sensitive_identity identity
  where identity.member_id = p_member_id for update;
  if target_member.id is null or target_member_season.id is null or target_identity.member_id is null then
    raise exception 'MEMBER_PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if private.member_profile_revision(p_member_id, p_member_season_id)
    <> p_expected_revision
  then
    raise exception 'MEMBER_PROFILE_STALE' using errcode = '40001';
  end if;

  if target_member.first_name is distinct from first_name then changed_fields := array_append(changed_fields, 'firstName'); end if;
  if target_member.insertion is distinct from insertion then changed_fields := array_append(changed_fields, 'insertion'); end if;
  if target_member.last_name is distinct from last_name then changed_fields := array_append(changed_fields, 'lastName'); end if;
  if target_member.email is distinct from email then changed_fields := array_append(changed_fields, 'email'); end if;
  if target_identity.date_of_birth is distinct from p_date_of_birth then changed_fields := array_append(changed_fields, 'dateOfBirth'); end if;
  if target_member.gender is distinct from p_gender then changed_fields := array_append(changed_fields, 'gender'); end if;
  if target_member_season.team_name is distinct from team then changed_fields := array_append(changed_fields, 'team'); end if;

  update app.members
  set first_name = first_name,
      insertion = insertion,
      last_name = last_name,
      email = email,
      gender = p_gender,
      team = team
  where id = p_member_id;

  update private.member_sensitive_identity
  set date_of_birth = p_date_of_birth,
      source_import_batch_id = null,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where member_id = p_member_id;

  update app.member_seasons
  set team_name = team,
      reconciliation_status = case
        when team is null then 'legacy_unknown'::app.member_season_reconciliation
        else 'resolved'::app.member_season_reconciliation
      end,
      source_import_batch_id = null,
      updated_at = timezone('utc', now())
  where id = p_member_season_id;

  if cardinality(changed_fields) > 0 then
    insert into app.audit_logs(
      actor_user_id, action, entity_type, entity_id, metadata, correlation_id
    ) values (
      actor,
      'member.profile.updated',
      'member',
      p_member_id,
      jsonb_build_object(
        'memberSeasonId', p_member_season_id,
        'seasonId', active_season_id,
        'changedFields', to_jsonb(changed_fields),
        'changedCount', cardinality(changed_fields),
        'requestId', p_request_id,
        'portalAccessUnchanged', true,
        'reason', reason
      ),
      p_correlation_id
    );
  end if;

  result := app.get_member_detail_v6(p_member_id)
    || jsonb_build_object('reused', false);
  insert into private.member_profile_edit_requests(
    request_id, staff_user_id, member_id, member_season_id,
    request_hash, result_snapshot, correlation_id
  ) values (
    p_request_id, actor, p_member_id, p_member_season_id,
    request_hash, result, p_correlation_id
  );
  return result;
end;
$$;

create or replace function private.release_order_line_inventory_v1(
  p_order_line_id uuid,
  p_reason text,
  p_actor uuid,
  p_request_id uuid,
  p_correlation_id uuid
)
returns integer
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  allocation app.inventory_allocations%rowtype;
  released_count integer := 0;
  target_order_id uuid;
  target_season_id uuid;
begin
  perform private.lock_inventory_mutation();
  select line.order_id, orders.season_id into target_order_id, target_season_id
  from app.order_lines line
  join app.member_orders orders on orders.id = line.order_id
  where line.id = p_order_line_id;
  if target_order_id is null then
    raise exception 'ORDER_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists(
    select 1 from app.inventory_reservations reservation
    where reservation.order_line_id = p_order_line_id
      and reservation.status = 'reserved'
      and not exists(
        select 1 from app.inventory_allocations candidate_allocation
        where candidate_allocation.legacy_reservation_id = reservation.id
          and candidate_allocation.status = 'reserved'
      )
  ) then
    raise exception 'INVENTORY_RECONCILIATION_REQUIRED' using errcode = '23514';
  end if;

  for allocation in
    select current_allocation.*
    from app.inventory_allocations current_allocation
    where current_allocation.order_line_id = p_order_line_id
      and current_allocation.status = 'reserved'
    order by current_allocation.article_variant_id, current_allocation.id
    for update
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'inventory-balance:' || allocation.season_id::text || ':' || allocation.article_variant_id::text,
      0
    ));
    insert into app.inventory_movements(
      season_id, article_id, article_variant_id, movement_type,
      reserved_delta, allocation_id, source_type, source_id,
      reason_code, idempotency_key, actor_user_id, correlation_id, safe_context
    ) values (
      allocation.season_id, allocation.article_id, allocation.article_variant_id,
      'allocation_released', -allocation.quantity, allocation.id,
      'member_size_edit', p_request_id, 'inventory.allocation_released',
      encode(extensions.digest(
        'member-size-release:' || allocation.id::text || ':' || p_request_id::text,
        'sha256'
      ), 'hex'),
      p_actor, p_correlation_id,
      jsonb_build_object(
        'allocationId', allocation.id,
        'orderItemId', allocation.order_line_id,
        'variantId', allocation.article_variant_id,
        'quantity', allocation.quantity
      )
    );
    perform set_config('app.inventory_internal', 'on', true);
    update app.inventory_allocations
    set status = 'released', released_at = timezone('utc', now()),
        released_by = p_actor, release_reason = p_reason,
        updated_at = timezone('utc', now())
    where id = allocation.id;
    if allocation.legacy_reservation_id is not null then
      update app.inventory_reservations
      set status = 'released', updated_at = timezone('utc', now())
      where id = allocation.legacy_reservation_id and status = 'reserved';
    end if;
    perform set_config('app.inventory_internal', 'off', true);
    insert into app.inventory_allocation_events(
      allocation_id, event_type, previous_status, next_status,
      reason_code, source_type, source_id, idempotency_key,
      actor_user_id, safe_context
    ) values (
      allocation.id, 'released', 'reserved', 'released',
      'inventory.allocation_released', 'member_size_edit', p_request_id,
      encode(extensions.digest(
        'member-size-release-event:' || allocation.id::text || ':' || p_request_id::text,
        'sha256'
      ), 'hex'),
      p_actor,
      jsonb_build_object(
        'allocationId', allocation.id,
        'orderItemId', allocation.order_line_id,
        'variantId', allocation.article_variant_id,
        'quantity', allocation.quantity
      )
    );
    released_count := released_count + 1;
  end loop;

  update private.qr_tokens
  set active = false,
      revoked_at = coalesce(revoked_at, timezone('utc', now())),
      revoked_by = coalesce(revoked_by, p_actor),
      revocation_reason = coalesce(revocation_reason, left(p_reason, 500))
  where order_id = target_order_id and active;
  return released_count;
end;
$$;

revoke all on function private.release_order_line_inventory_v1(
  uuid, text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function app.set_member_article_sizes_v2(
  p_member_id uuid,
  p_member_season_id uuid,
  p_sizes jsonb,
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
#variable_conflict use_variable
declare
  actor uuid := private.require_clothing_aal2();
  actor_role app.staff_role := app.staff_role();
  target_member_season app.member_seasons%rowtype;
  target_order app.member_orders%rowtype;
  target_line app.order_lines%rowtype;
  item jsonb;
  target_article_id uuid;
  target_variant_id uuid;
  release_reserved boolean;
  reason text := nullif(btrim(regexp_replace(normalize(p_reason, NFKC), '[[:space:]]+', ' ', 'g')), '');
  request_hash text;
  previous private.member_size_edit_requests%rowtype;
  has_reservation boolean;
  has_issuance boolean;
  has_history boolean;
  changed_article_ids uuid[] := array[]::uuid[];
  released_count integer := 0;
  new_line_id uuid;
  result jsonb;
begin
  if p_member_id is null or p_member_season_id is null or p_request_id is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_sizes is null or jsonb_typeof(p_sizes) <> 'array'
    or jsonb_array_length(p_sizes) not between 1 and 25
    or length(coalesce(reason, '')) not between 3 and 500
    or (select count(distinct entry->>'articleId') from jsonb_array_elements(p_sizes) entry)
      <> jsonb_array_length(p_sizes)
  then
    raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023';
  end if;

  request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'memberId', p_member_id,
    'memberSeasonId', p_member_season_id,
    'sizes', p_sizes,
    'expectedRevision', p_expected_revision,
    'reason', reason
  )::text, 'UTF8'), 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    'member-size-edit-request:' || p_request_id::text, 0
  ));
  select * into previous from private.member_size_edit_requests request
  where request.request_id = p_request_id;
  if found then
    if previous.staff_user_id <> actor or previous.request_hash <> request_hash then
      raise exception 'MEMBER_SIZE_REQUEST_REUSED' using errcode = '40001';
    end if;
    return previous.result_snapshot;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'dynamic-import-member:' || p_member_id::text, 0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'dynamic-import-member-season:' || p_member_season_id::text, 0
  ));
  select member_season.* into target_member_season
  from app.member_seasons member_season
  join app.seasons season on season.id = member_season.season_id
  where member_season.id = p_member_season_id
    and member_season.member_id = p_member_id
    and member_season.participation_status = 'active'
    and member_season.reconciliation_status = 'resolved'
    and season.status = 'open'
  for update of member_season;
  if target_member_season.id is null then
    raise exception 'MEMBER_NOT_ACTIVE' using errcode = '23514';
  end if;
  perform 1 from app.member_article_sizes size_profile
  where size_profile.member_season_id = p_member_season_id for update;
  select orders.* into target_order from app.member_orders orders
  where orders.member_season_id = p_member_season_id for update;
  if private.member_size_revision_v2(p_member_season_id) <> p_expected_revision then
    raise exception 'MEMBER_SIZES_CONFLICT' using errcode = '40001';
  end if;

  perform set_config('app.size_correlation_id', coalesce(p_correlation_id::text, ''), true);
  perform set_config('app.size_client_request_id', p_request_id::text, true);
  perform set_config('app.size_change_request_id', '', true);
  perform set_config('app.size_import_run_id', '', true);
  perform set_config('app.size_import_source_row', '', true);

  for item in select value from jsonb_array_elements(p_sizes)
  loop
    if jsonb_typeof(item) <> 'object'
      or not (item ? 'articleId' and item ? 'variantId' and item ? 'releaseReserved')
      or (select count(*) from jsonb_object_keys(item)) <> 3
      or coalesce(item->>'articleId', '') !~ '^[0-9a-fA-F-]{36}$'
      or (item->'variantId' <> 'null'::jsonb and coalesce(item->>'variantId', '') !~ '^[0-9a-fA-F-]{36}$')
      or jsonb_typeof(item->'releaseReserved') <> 'boolean'
    then
      raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023';
    end if;
    target_article_id := (item->>'articleId')::uuid;
    target_variant_id := nullif(item->>'variantId', '')::uuid;
    release_reserved := (item->>'releaseReserved')::boolean;

    if not exists(
      select 1 from app.articles article
      join app.article_seasons link
        on link.article_id = article.id
        and link.season_id = target_member_season.season_id
      where article.id = target_article_id and article.active
    ) then
      raise exception 'MEMBER_SIZE_ARTICLE_INVALID' using errcode = '22023';
    end if;
    if target_variant_id is not null and not exists(
      select 1 from app.article_variants variant
      where variant.id = target_variant_id
        and variant.article_id = target_article_id
        and variant.active
    ) then
      raise exception 'MEMBER_SIZE_VARIANT_INVALID' using errcode = '22023';
    end if;

    target_line := null;
    if target_order.id is not null then
      select line.* into target_line from app.order_lines line
      where line.order_id = target_order.id
        and line.article_id = target_article_id
        and line.status <> 'cancelled'
      order by line.created_at desc, line.id desc
      limit 1 for update;
    end if;
    has_reservation := target_line.id is not null and (
      exists(select 1 from app.inventory_allocations allocation
        where allocation.order_line_id = target_line.id and allocation.status = 'reserved')
      or exists(select 1 from app.inventory_reservations reservation
        where reservation.order_line_id = target_line.id and reservation.status = 'reserved')
    );
    has_issuance := target_line.id is not null and (
      target_line.status = 'picked_up'
      or exists(select 1 from app.inventory_allocations allocation
        where allocation.order_line_id = target_line.id and allocation.status = 'fulfilled')
      or exists(select 1 from app.inventory_reservations reservation
        where reservation.order_line_id = target_line.id and reservation.status = 'fulfilled')
      or exists(select 1 from app.fulfilment_lines fulfilment_line
        where fulfilment_line.order_line_id = target_line.id and fulfilment_line.reversed_at is null)
    );
    has_history := target_line.id is not null and (
      exists(select 1 from app.inventory_allocations allocation where allocation.order_line_id = target_line.id)
      or exists(select 1 from app.inventory_reservations reservation where reservation.order_line_id = target_line.id)
      or exists(select 1 from app.fulfilment_lines fulfilment_line where fulfilment_line.order_line_id = target_line.id)
    );

    if has_issuance and target_line.article_variant_id is distinct from target_variant_id then
      raise exception 'MEMBER_SIZE_ISSUED_LOCKED' using errcode = '23514';
    end if;
    if target_line.id is not null and target_variant_id is null then
      raise exception 'MEMBER_SIZE_ORDER_REQUIRES_VARIANT' using errcode = '23514';
    end if;
    if has_reservation and target_line.article_variant_id is distinct from target_variant_id then
      if actor_role <> 'beheerder' or not release_reserved then
        raise exception 'MEMBER_SIZE_RELEASE_CONFIRMATION_REQUIRED' using errcode = '23514';
      end if;
      released_count := released_count + private.release_order_line_inventory_v1(
        target_line.id, reason, actor, p_request_id, p_correlation_id
      );
    elsif release_reserved then
      raise exception 'MEMBER_SIZE_RELEASE_NOT_REQUIRED' using errcode = '22023';
    end if;

    if target_variant_id is null then
      delete from app.member_article_sizes size_profile
      where size_profile.member_season_id = p_member_season_id
        and size_profile.article_id = target_article_id;
    else
      update app.package_size_change_requests request
      set status = 'superseded',
          resolved_at = timezone('utc', now()),
          resolved_by = null,
          resolution_reason = 'Vervallen door geaudite beheerdercorrectie'
      where request.order_line_id = target_line.id
        and request.status = 'requested';
      insert into app.member_article_sizes(
        member_id, season_id, member_season_id, article_id,
        article_variant_id, selection_status, selection_source,
        raw_value, member_note, confirmed_at, confirmed_by,
        confirmed_by_parent_account_id, requested_article_variant_id,
        requested_raw_value, requested_member_note, requested_at,
        requested_by_parent_account_id, created_by, updated_by
      ) values (
        p_member_id, target_member_season.season_id, p_member_season_id,
        target_article_id, target_variant_id, 'confirmed', 'staff',
        null, null, timezone('utc', now()), actor, null,
        null, null, null, null, null, actor, actor
      )
      on conflict(member_id, season_id, article_id) do update
      set article_variant_id = excluded.article_variant_id,
          selection_status = 'confirmed', selection_source = 'staff',
          raw_value = null, member_note = null,
          confirmed_at = excluded.confirmed_at, confirmed_by = actor,
          confirmed_by_parent_account_id = null,
          requested_article_variant_id = null, requested_raw_value = null,
          requested_member_note = null, requested_at = null,
          requested_by_parent_account_id = null, updated_by = actor,
          updated_at = timezone('utc', now());
    end if;

    if target_line.id is not null
      and target_line.article_variant_id is distinct from target_variant_id
    then
      perform set_config('app.package_size_internal', 'on', true);
      if has_history then
        update app.order_lines set status = 'cancelled',
          updated_at = timezone('utc', now())
        where id = target_line.id;
        insert into app.order_lines(
          order_id, article_variant_id, quantity, package_template_item_id, status
        ) values (
          target_line.order_id, target_variant_id, target_line.quantity,
          target_line.package_template_item_id, 'backorder'
        ) returning id into new_line_id;
      else
        update app.order_lines
        set article_variant_id = target_variant_id,
            updated_at = timezone('utc', now())
        where id = target_line.id;
        new_line_id := target_line.id;
      end if;
      perform set_config('app.package_size_internal', 'off', true);
      perform app.refresh_order_status(target_line.order_id);
      perform private.enqueue_inventory_variant(
        target_member_season.season_id,
        target_line.article_variant_id,
        'size.staff_corrected'
      );
      perform private.enqueue_inventory_variant(
        target_member_season.season_id,
        target_variant_id,
        'size.staff_corrected'
      );
    end if;
    changed_article_ids := array_append(changed_article_ids, target_article_id);
  end loop;

  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  ) values (
    actor,
    'member.sizes.updated',
    'member',
    p_member_id,
    jsonb_build_object(
      'memberSeasonId', p_member_season_id,
      'seasonId', target_member_season.season_id,
      'articleIds', to_jsonb(changed_article_ids),
      'changedCount', cardinality(changed_article_ids),
      'releasedAllocationCount', released_count,
      'requestId', p_request_id,
      'reason', reason
    ),
    p_correlation_id
  );
  result := private.member_size_profile_json_v3(p_member_season_id);
  insert into private.member_size_edit_requests(
    request_id, staff_user_id, member_id, member_season_id,
    request_hash, result_snapshot, correlation_id
  ) values (
    p_request_id, actor, p_member_id, p_member_season_id,
    request_hash, result, p_correlation_id
  );
  return result;
end;
$$;

revoke all on function private.member_size_profile_json_v3(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.member_size_profile_json(uuid)
from public, anon, authenticated, service_role;
revoke all on function app.get_member_detail_v6(uuid)
from public, anon, service_role;
revoke all on function app.update_member_profile_v1(
  uuid, uuid, text, text, text, text, date, app.gender_code,
  text, text, text, uuid, uuid
) from public, anon, service_role;
revoke all on function app.set_member_article_sizes_v2(
  uuid, uuid, jsonb, text, text, uuid, uuid
) from public, anon, service_role;
grant execute on function app.get_member_detail_v6(uuid) to authenticated;
grant execute on function app.update_member_profile_v1(
  uuid, uuid, text, text, text, text, date, app.gender_code,
  text, text, text, uuid, uuid
) to authenticated;
grant execute on function app.set_member_article_sizes_v2(
  uuid, uuid, jsonb, text, text, uuid, uuid
) to authenticated;

notify pgrst, 'reload schema';
