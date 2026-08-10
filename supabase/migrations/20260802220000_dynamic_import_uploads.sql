-- Encrypted, short-lived upload staging for the dynamic Sportlink import.
--
-- Raw CSV bytes are encrypted by the application before they enter PostgreSQL.
-- Only a narrow service-role RPC can retrieve ciphertext. Application roles see
-- safe batch metadata and never receive durable source values before a mapping is
-- explicitly selected.

do $$ begin
  create type app.dynamic_import_status as enum (
    'uploaded',
    'previewed',
    'processing',
    'committed',
    'failed',
    'expired'
  );
exception when duplicate_object then null; end $$;

alter table app.import_batches
  add column season_id uuid references app.seasons(id) on delete restrict,
  add column client_request_id uuid,
  add column schema_version integer,
  add column dynamic_status app.dynamic_import_status,
  add column encoding text,
  add column delimiter text,
  add column byte_count integer,
  add column source_row_count integer,
  add column source_column_count integer,
  add column policy jsonb,
  add column mapping_hash text,
  add column catalog_hash text,
  add column preview_revision integer not null default 0,
  add column next_source_row integer,
  add column expires_at timestamptz,
  add column failure_code text,
  add constraint import_batches_dynamic_shape_check check (
    (
      schema_version is null
      and dynamic_status is null
      and client_request_id is null
    )
    or (
      schema_version = 2
      and dynamic_status is not null
      and client_request_id is not null
      and season_id is not null
      and encoding = 'UTF-8'
      and delimiter in (',', ';')
      and byte_count between 1 and 10485760
      and source_row_count between 1 and 10000
      and source_column_count between 1 and 64
      and expires_at is not null
      and (mapping_hash is null or mapping_hash ~ '^[0-9a-f]{64}$')
      and (catalog_hash is null or catalog_hash ~ '^[0-9a-f]{64}$')
      and (next_source_row is null or next_source_row between 2 and 10002)
      and (failure_code is null or failure_code ~ '^[a-z0-9][a-z0-9._-]{0,63}$')
    )
  );

create unique index import_batches_dynamic_request_idx
  on app.import_batches(actor_user_id, client_request_id)
  where schema_version = 2;

create index import_batches_dynamic_expiry_idx
  on app.import_batches(expires_at)
  where schema_version = 2
    and dynamic_status in ('uploaded', 'previewed', 'processing');

create table private.import_staging_payloads (
  batch_id uuid primary key references app.import_batches(id) on delete restrict,
  ciphertext_base64 text not null check (
    length(ciphertext_base64) between 24 and 14000000
    and ciphertext_base64 ~ '^[A-Za-z0-9+/]+={0,2}$'
  ),
  nonce_base64 text not null check (
    length(nonce_base64) = 16
    and nonce_base64 ~ '^[A-Za-z0-9+/]{16}$'
  ),
  key_version integer not null check (key_version between 1 and 100),
  key_fingerprint text not null check (key_fingerprint ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default timezone('utc', now()),
  constraint import_staging_expiry_check check (expires_at > created_at)
);

create index import_staging_payloads_expiry_idx
  on private.import_staging_payloads(expires_at);

alter table private.import_staging_payloads enable row level security;
revoke all on table private.import_staging_payloads
from public, anon, authenticated, service_role;

drop policy if exists "staff can read imports" on app.import_batches;
drop policy if exists "operations can create imports" on app.import_batches;
drop policy if exists "operations can read imports" on app.import_batches;
create policy "operations can read legacy imports"
on app.import_batches
for select
using (
  schema_version is null
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);
create policy "administrators can read import batches"
on app.import_batches
for select
using (
  schema_version = 2
  and coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);

create or replace function private.require_dynamic_import_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null
    or coalesce(auth.jwt()->>'aal', '') <> 'aal2'
    or not exists(
      select 1
      from app.staff_profiles profile
      where profile.auth_user_id = actor
        and profile.active
        and profile.role = 'beheerder'
    )
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return actor;
end;
$$;

revoke all on function private.require_dynamic_import_admin()
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce((
    select flag.enabled
    from app.release_feature_flags flag
    where flag.key = 'dynamic_import_v2'
  ), false);
$$;

revoke all on function private.dynamic_import_enabled()
from public, anon, authenticated, service_role;

-- Preserve the compatibility RPC while the v2 gates are off, but make the
-- database itself authoritative at cutover. The legacy commit RPC calls this
-- summary first and therefore cannot write around the same gate.
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
  if private.dynamic_import_enabled() then
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
    left join app.members member on upper(member.relation_number) = incoming.relation_number
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

create or replace function app.get_dynamic_import_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
begin
  actor := private.require_dynamic_import_admin();
  return jsonb_build_object(
    'featureEnabled', private.dynamic_import_enabled(),
    'activeSeason', (
      select jsonb_build_object('id', season.id, 'name', season.name)
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
    ),
    'limits', jsonb_build_object(
      'maxBytes', 10485760,
      'maxRows', 10000,
      'maxColumns', 64,
      'maxCellLength', 512,
      'retentionHoursDefault', 24,
      'retentionHoursMinimum', 1,
      'retentionHoursMaximum', 72
    ),
    'recentBatches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', batch.id,
        'fileName', batch.file_name,
        'status', batch.dynamic_status::text,
        'rowCount', batch.source_row_count,
        'createdAt', batch.created_at,
        'expiresAt', batch.expires_at,
        'committedAt', batch.committed_at
      ) order by batch.created_at desc)
      from (
        select import_batch.*
        from app.import_batches import_batch
        where import_batch.schema_version = 2
          and import_batch.actor_user_id = actor
        order by import_batch.created_at desc
        limit 10
      ) batch
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.create_dynamic_import_upload(
  p_batch_id uuid,
  p_client_request_id uuid,
  p_season_id uuid,
  p_file_name text,
  p_checksum text,
  p_delimiter text,
  p_byte_count integer,
  p_row_count integer,
  p_column_count integer,
  p_ciphertext_base64 text,
  p_nonce_base64 text,
  p_key_version integer,
  p_key_fingerprint text,
  p_retention_hours integer,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  existing app.import_batches%rowtype;
  expires timestamptz;
begin
  actor := private.require_dynamic_import_admin();
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_batch_id is null
    or p_client_request_id is null
    or p_season_id is null
    or p_file_name is null
    or length(trim(p_file_name)) not between 1 and 255
    or p_checksum is null
    or p_checksum !~ '^[0-9a-f]{64}$'
    or p_delimiter is null
    or p_delimiter not in (',', ';')
    or p_byte_count is null
    or p_byte_count not between 1 and 10485760
    or p_row_count is null
    or p_row_count not between 1 and 10000
    or p_column_count is null
    or p_column_count not between 1 and 64
    or p_ciphertext_base64 is null
    or length(p_ciphertext_base64) not between 24 and 14000000
    or p_ciphertext_base64 !~ '^[A-Za-z0-9+/]+={0,2}$'
    or p_nonce_base64 is null
    or length(p_nonce_base64) <> 16
    or p_nonce_base64 !~ '^[A-Za-z0-9+/]{16}$'
    or p_key_version is null
    or p_key_version not between 1 and 100
    or p_key_fingerprint is null
    or p_key_fingerprint !~ '^[0-9a-f]{64}$'
    or p_retention_hours is null
    or p_retention_hours not between 1 and 72
  then
    raise exception 'DYNAMIC_IMPORT_UPLOAD_INVALID' using errcode = '22023';
  end if;
  if not exists(
    select 1
    from app.app_settings settings
    join app.seasons season on season.id = settings.active_season_id
    where settings.id = true
      and season.id = p_season_id
      and season.status = 'open'
  ) then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('dynamic-import-upload:' || actor::text || ':' || p_client_request_id::text, 0)
  );
  select *
  into existing
  from app.import_batches batch
  where batch.actor_user_id = actor
    and batch.client_request_id = p_client_request_id
    and batch.schema_version = 2
  for update;

  if found then
    if existing.checksum is distinct from p_checksum
      or existing.season_id is distinct from p_season_id
      or existing.byte_count is distinct from p_byte_count
    then
      raise exception 'DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if existing.dynamic_status = 'expired'
      or existing.expires_at <= timezone('utc', now())
      or not exists(
        select 1
        from private.import_staging_payloads payload
        where payload.batch_id = existing.id
      )
    then
      raise exception 'DYNAMIC_IMPORT_UPLOAD_EXPIRED' using errcode = '55000';
    end if;
    return jsonb_build_object(
      'batchId', existing.id,
      'status', existing.dynamic_status::text,
      'expiresAt', existing.expires_at,
      'reused', true
    );
  end if;

  expires := timezone('utc', now()) + make_interval(hours => p_retention_hours);
  insert into app.import_batches(
    id,
    file_name,
    checksum,
    mapping,
    actor_user_id,
    row_counts,
    status,
    season_id,
    client_request_id,
    schema_version,
    dynamic_status,
    encoding,
    delimiter,
    byte_count,
    source_row_count,
    source_column_count,
    policy,
    expires_at
  )
  values(
    p_batch_id,
    trim(p_file_name),
    p_checksum,
    '{}'::jsonb,
    actor,
    jsonb_build_object('uploaded', p_row_count),
    'preview',
    p_season_id,
    p_client_request_id,
    2,
    'uploaded',
    'UTF-8',
    p_delimiter,
    p_byte_count,
    p_row_count,
    p_column_count,
    jsonb_build_object(
      'retentionHours', p_retention_hours,
      'confirmedValuesProtected', true,
      'emptyValuesOverwrite', false
    ),
    expires
  );

  insert into private.import_staging_payloads(
    batch_id,
    ciphertext_base64,
    nonce_base64,
    key_version,
    key_fingerprint,
    expires_at
  )
  values(
    p_batch_id,
    p_ciphertext_base64,
    p_nonce_base64,
    p_key_version,
    p_key_fingerprint,
    expires
  );

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
    'members.import.upload.staged',
    'import_batch',
    p_batch_id,
    jsonb_build_object(
      'schemaVersion', 2,
      'byteCount', p_byte_count,
      'rowCount', p_row_count,
      'columnCount', p_column_count,
      'retentionHours', p_retention_hours
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'batchId', p_batch_id,
    'status', 'uploaded',
    'expiresAt', expires,
    'reused', false
  );
exception
  when unique_violation then
    raise exception 'DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.read_dynamic_import_payload(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  if p_batch_id is null then
    raise exception 'DYNAMIC_IMPORT_BATCH_INVALID' using errcode = '22023';
  end if;
  select jsonb_build_object(
    'batchId', batch.id,
    'seasonId', batch.season_id,
    'checksum', batch.checksum,
    'fileName', batch.file_name,
    'delimiter', batch.delimiter,
    'rowCount', batch.source_row_count,
    'columnCount', batch.source_column_count,
    'status', batch.dynamic_status::text,
    'expiresAt', batch.expires_at,
    'ciphertext', payload.ciphertext_base64,
    'nonce', payload.nonce_base64,
    'keyVersion', payload.key_version
  )
  into result
  from app.import_batches batch
  join private.import_staging_payloads payload on payload.batch_id = batch.id
  where batch.id = p_batch_id
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

create or replace function app.cleanup_expired_security_data_v2(p_now timestamptz)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  legacy_result jsonb;
  import_staging_count integer;
begin
  if p_now is null then
    raise exception 'INVALID_RETENTION_TIMESTAMP' using errcode = '22023';
  end if;
  legacy_result := app.cleanup_expired_security_data(p_now);

  with expired as (
    delete from private.import_staging_payloads payload
    where payload.expires_at <= p_now
    returning payload.batch_id
  ),
  marked as (
    update app.import_batches batch
    set dynamic_status = 'expired',
        failure_code = 'raw_retention_expired'
    where batch.id in (select expired.batch_id from expired)
      and batch.dynamic_status in ('uploaded', 'previewed', 'processing')
    returning 1
  )
  select count(*)::integer into import_staging_count from marked;

  return legacy_result || jsonb_build_object('importStaging', import_staging_count);
end;
$$;

create or replace function app.get_operational_health_v3()
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select app.get_operational_health_v2() || jsonb_build_object(
    'importStaging',
    jsonb_build_object(
      'pending', (
        select count(*)
        from private.import_staging_payloads payload
        where payload.expires_at > timezone('utc', now())
      ),
      'expired', (
        select count(*)
        from private.import_staging_payloads payload
        where payload.expires_at <= timezone('utc', now())
      ),
      'oldestExpiresAt', (
        select min(payload.expires_at)
        from private.import_staging_payloads payload
        where payload.expires_at > timezone('utc', now())
      )
    )
  );
$$;

create or replace function app.assert_dynamic_import_staging_key(
  p_key_fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  pending_count integer;
  incompatible_count integer;
begin
  if p_key_fingerprint is not null
    and p_key_fingerprint !~ '^[0-9a-f]{64}$'
  then
    raise exception 'IMPORT_STAGING_KEY_FINGERPRINT_INVALID' using errcode = '22023';
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where p_key_fingerprint is null
        or payload.key_fingerprint is distinct from p_key_fingerprint
    )::integer
  into pending_count, incompatible_count
  from private.import_staging_payloads payload
  join app.import_batches batch on batch.id = payload.batch_id
  where payload.expires_at > timezone('utc', now())
    and batch.dynamic_status in ('uploaded', 'previewed', 'processing');

  if incompatible_count > 0 then
    raise exception 'IMPORT_STAGING_KEY_ROTATION_BLOCKED' using errcode = '55000';
  end if;

  return jsonb_build_object(
    'compatible', true,
    'pending', pending_count
  );
end;
$$;

revoke all on function app.get_dynamic_import_workspace()
from public, anon;
grant execute on function app.get_dynamic_import_workspace()
to authenticated;

revoke all on function app.create_dynamic_import_upload(
  uuid, uuid, uuid, text, text, text, integer, integer, integer,
  text, text, integer, text, integer, uuid
) from public, anon;
grant execute on function app.create_dynamic_import_upload(
  uuid, uuid, uuid, text, text, text, integer, integer, integer,
  text, text, integer, text, integer, uuid
) to authenticated;

revoke all on function app.read_dynamic_import_payload(uuid)
from public, anon, authenticated;
grant execute on function app.read_dynamic_import_payload(uuid)
to service_role;

revoke all on function app.cleanup_expired_security_data_v2(timestamptz)
from public, anon, authenticated;
grant execute on function app.cleanup_expired_security_data_v2(timestamptz)
to service_role;

revoke all on function app.get_operational_health_v3()
from public, anon, authenticated;
grant execute on function app.get_operational_health_v3()
to service_role;

revoke all on function app.assert_dynamic_import_staging_key(text)
from public, anon, authenticated;
grant execute on function app.assert_dynamic_import_staging_key(text)
to service_role;

notify pgrst, 'reload schema';
