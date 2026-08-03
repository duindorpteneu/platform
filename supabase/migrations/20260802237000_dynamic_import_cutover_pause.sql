-- Keep the dynamic-import cutover one-way while retaining an operational
-- database pause. Disabling the v2 flag pauses v2 processing, but the durable
-- cutover marker continues to reject every legacy import write path.

create or replace function private.dynamic_import_cutover_active()
returns boolean
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select exists(
    select 1
    from private.release_cutovers cutover
    where cutover.key = 'dynamic_import_v2'
  );
$$;

revoke all on function private.dynamic_import_cutover_active()
from public, anon, authenticated, service_role;

create or replace function private.guard_irreversible_release_cutover()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if old.key <> 'dynamic_import_v2' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'DELETE' then
    if private.dynamic_import_cutover_active() then
      raise exception 'DYNAMIC_IMPORT_CUTOVER_IRREVERSIBLE'
        using errcode = '55000';
    end if;
    return old;
  end if;

  if new.key is distinct from old.key then
    raise exception 'DYNAMIC_IMPORT_CUTOVER_KEY_IMMUTABLE'
      using errcode = '55000';
  end if;
  if new.enabled then
    insert into private.release_cutovers(key)
    values(new.key)
    on conflict (key) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function private.guard_irreversible_release_cutover()
from public, anon, authenticated, service_role;

create or replace function app.get_sportlink_import_summary(p_members jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  new_count integer;
  updated_count integer;
  unchanged_count integer;
begin
  if private.dynamic_import_cutover_active() then
    raise exception 'LEGACY_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if jsonb_typeof(p_members) <> 'array'
    or jsonb_array_length(p_members) = 0
    or jsonb_array_length(p_members) > 10000
  then
    raise exception 'INVALID_IMPORT_ROWS' using errcode = '22023';
  end if;

  with incoming as (
    select
      upper(trim(row_data.relation_number)) as relation_number,
      trim(row_data.first_name) as first_name,
      nullif(trim(row_data.insertion), '') as insertion,
      trim(row_data.last_name) as last_name,
      lower(trim(row_data.email)) as email,
      trim(row_data.team) as team,
      row_data.active_for_season
    from jsonb_to_recordset(p_members) as row_data(
      relation_number text,
      first_name text,
      insertion text,
      last_name text,
      email text,
      team text,
      active_for_season boolean
    )
  ),
  compared as (
    select
      member.id is null as is_new,
      member.id is not null and (
        member.first_name is distinct from incoming.first_name
        or member.insertion is distinct from incoming.insertion
        or member.last_name is distinct from incoming.last_name
        or member.email is distinct from incoming.email
        or member.team is distinct from incoming.team
        or member.active_for_season is distinct from incoming.active_for_season
      ) as is_updated
    from incoming
    left join app.members member
      on upper(member.relation_number) = incoming.relation_number
  )
  select
    count(*) filter (where is_new)::integer,
    count(*) filter (where not is_new and is_updated)::integer,
    count(*) filter (where not is_new and not is_updated)::integer
  into new_count, updated_count, unchanged_count
  from compared;

  return jsonb_build_object(
    'total', jsonb_array_length(p_members),
    'new', new_count,
    'updated', updated_count,
    'unchanged', unchanged_count
  );
end;
$$;

notify pgrst, 'reload schema';
