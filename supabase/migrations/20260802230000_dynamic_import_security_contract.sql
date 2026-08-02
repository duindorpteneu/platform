-- Security contract for dynamic-import processing.
--
-- Once the database cutover has been activated it is intentionally one-way:
-- pausing remains possible through the runtime gate, but the legacy write RPCs
-- can never be reopened by toggling the database flag back to false.
-- Ciphertext reads are bound to the authenticated actor context captured by the
-- application and to the exact season and optimistic preview revision.

create table private.release_cutovers (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{2,63}$'),
  activated_at timestamptz not null default timezone('utc', now())
);

alter table private.release_cutovers enable row level security;
revoke all on table private.release_cutovers
from public, anon, authenticated, service_role;

insert into private.release_cutovers(key)
select 'dynamic_import_v2'
where exists(
  select 1
  from app.release_feature_flags
  where key = 'dynamic_import_v2'
    and enabled
)
on conflict (key) do nothing;

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
    if exists(select 1 from private.release_cutovers where key = old.key) then
      raise exception 'DYNAMIC_IMPORT_CUTOVER_IRREVERSIBLE' using errcode = '55000';
    end if;
    return old;
  end if;

  if new.key is distinct from old.key then
    raise exception 'DYNAMIC_IMPORT_CUTOVER_KEY_IMMUTABLE' using errcode = '55000';
  end if;
  if old.enabled and not new.enabled then
    raise exception 'DYNAMIC_IMPORT_CUTOVER_IRREVERSIBLE' using errcode = '55000';
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

create trigger release_feature_flags_irreversible_cutover
before update or delete on app.release_feature_flags
for each row execute function private.guard_irreversible_release_cutover();

create or replace function app.read_dynamic_import_payload_bound(
  p_batch_id uuid,
  p_actor_id uuid,
  p_season_id uuid,
  p_preview_revision integer
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
  if p_batch_id is null
    or p_actor_id is null
    or p_season_id is null
    or p_preview_revision is null
    or p_preview_revision < 0
  then
    raise exception 'DYNAMIC_IMPORT_BINDING_INVALID' using errcode = '22023';
  end if;

  select jsonb_build_object(
    'batchId', batch.id,
    'actorId', batch.actor_user_id,
    'seasonId', batch.season_id,
    'previewRevision', batch.preview_revision,
    'checksum', batch.checksum,
    'fileName', batch.file_name,
    'delimiter', batch.delimiter,
    'rowCount', batch.source_row_count,
    'columnCount', batch.source_column_count,
    'status', batch.dynamic_status::text,
    'expiresAt', batch.expires_at,
    'ciphertext', payload.ciphertext_base64,
    'nonce', payload.nonce_base64,
    'keyVersion', payload.key_version,
    'keyFingerprint', payload.key_fingerprint
  )
  into result
  from app.import_batches batch
  join private.import_staging_payloads payload on payload.batch_id = batch.id
  where batch.id = p_batch_id
    and batch.actor_user_id = p_actor_id
    and batch.season_id = p_season_id
    and batch.preview_revision = p_preview_revision
    and batch.schema_version = 2
    and batch.dynamic_status in ('uploaded', 'previewed', 'processing')
    and batch.expires_at > timezone('utc', now())
    and payload.expires_at > timezone('utc', now());

  if result is null then
    raise exception 'DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE' using errcode = 'P0002';
  end if;
  return result;
end;
$$;

-- Keep the old function body for migration rollback compatibility, but remove
-- every callable grant so new application code cannot bypass the binding.
revoke all on function app.read_dynamic_import_payload(uuid)
from public, anon, authenticated, service_role;

revoke all on function app.read_dynamic_import_payload_bound(uuid, uuid, uuid, integer)
from public, anon, authenticated;
grant execute on function app.read_dynamic_import_payload_bound(uuid, uuid, uuid, integer)
to service_role;

notify pgrst, 'reload schema';
