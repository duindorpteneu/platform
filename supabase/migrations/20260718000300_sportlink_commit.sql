create or replace function app.commit_sportlink_import(
  p_file_name text,
  p_checksum text,
  p_mapping jsonb,
  p_members jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  batch_id uuid;
  imported_count integer := 0;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  if p_file_name is null or length(trim(p_file_name)) = 0 or length(p_file_name) > 255 then
    raise exception 'INVALID_IMPORT_FILE_NAME' using errcode = '22023';
  end if;
  if p_checksum is null or length(p_checksum) <> 64 then
    raise exception 'INVALID_IMPORT_CHECKSUM' using errcode = '22023';
  end if;
  if jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) = 0 or jsonb_array_length(p_members) > 10000 then
    raise exception 'INVALID_IMPORT_ROWS' using errcode = '22023';
  end if;

  insert into app.import_batches (file_name, checksum, mapping, actor_user_id, row_counts, status, committed_at)
  values (left(trim(p_file_name), 255), lower(p_checksum), coalesce(p_mapping, '{}'::jsonb), actor,
    jsonb_build_object('total', jsonb_array_length(p_members)), 'committed', timezone('utc', now()))
  returning id into batch_id;

  insert into app.members (
    relation_number, first_name, insertion, last_name, email, team, active_for_season, imported_from_batch_id
  )
  select
    upper(trim(row_data.relation_number)),
    trim(row_data.first_name),
    nullif(trim(row_data.insertion), ''),
    trim(row_data.last_name),
    lower(trim(row_data.email)),
    trim(row_data.team),
    row_data.active_for_season,
    batch_id
  from jsonb_to_recordset(p_members) as row_data(
    relation_number text,
    first_name text,
    insertion text,
    last_name text,
    email text,
    team text,
    active_for_season boolean
  )
  on conflict (relation_number) do update set
    first_name = excluded.first_name,
    insertion = excluded.insertion,
    last_name = excluded.last_name,
    email = excluded.email,
    team = excluded.team,
    active_for_season = excluded.active_for_season,
    imported_from_batch_id = excluded.imported_from_batch_id,
    updated_at = timezone('utc', now());

  get diagnostics imported_count = row_count;

  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata)
  values (actor, 'members.import.commit', 'import_batch', batch_id,
    jsonb_build_object('file_name', left(trim(p_file_name), 255), 'checksum', lower(p_checksum), 'row_count', imported_count));

  return jsonb_build_object('batchId', batch_id, 'upserted', imported_count);
end;
$$;

revoke all on function app.commit_sportlink_import(text, text, jsonb, jsonb) from public, anon;
grant execute on function app.commit_sportlink_import(text, text, jsonb, jsonb) to authenticated;
