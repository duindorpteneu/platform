-- Persistent, resumable dry-runs for the dynamic Sportlink import.
--
-- The browser never submits member data to the dry-run API. A service-only
-- worker decrypts the actor/season/revision-bound upload, projects only mapped
-- columns, and stages those selected values for at most the upload retention
-- window. Public result rows contain source row numbers and safe reason codes,
-- never names, e-mail addresses, DOB values or ignored source data.

do $$ begin
  create type app.dynamic_import_run_status as enum (
    'queued_preview',
    'staging',
    'previewed',
    'commit_queued',
    'committing',
    'committed',
    'failed',
    'expired'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.dynamic_import_row_outcome as enum (
    'create',
    'update',
    'skip',
    'protected',
    'conflict',
    'error'
  );
exception when duplicate_object then null; end $$;

create table app.dynamic_import_runs (
  id uuid primary key,
  batch_id uuid not null references app.import_batches(id) on delete restrict,
  mapping_revision_id uuid not null,
  season_id uuid not null references app.seasons(id) on delete restrict,
  created_by uuid not null,
  client_request_id uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status app.dynamic_import_run_status not null default 'queued_preview',
  source_row_count integer not null check (source_row_count between 1 and 10000),
  next_source_row integer not null default 2 check (next_source_row between 2 and 10002),
  next_analysis_source_row integer not null default 2
    check (next_analysis_source_row between 2 and 10002),
  next_commit_source_row integer not null default 2
    check (next_commit_source_row between 2 and 10002),
  outcome_counts jsonb not null default jsonb_build_object(
    'create', 0,
    'update', 0,
    'skip', 0,
    'protected', 0,
    'conflict', 0,
    'error', 0
  ),
  has_blockers boolean not null default false,
  plan_hash text check (plan_hash is null or plan_hash ~ '^[0-9a-f]{64}$'),
  attempt_count integer not null default 0 check (attempt_count between 0 and 1000),
  failure_code text check (
    failure_code is null or failure_code ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
  ),
  expires_at timestamptz not null,
  created_at timestamptz not null default timezone('utc', now()),
  started_at timestamptz,
  previewed_at timestamptz,
  commit_requested_at timestamptz,
  committed_at timestamptz,
  failed_at timestamptz,
  constraint dynamic_import_runs_mapping_fkey
    foreign key (mapping_revision_id, batch_id, season_id)
    references app.import_mapping_revisions(id, batch_id, season_id)
    on delete restrict,
  constraint dynamic_import_runs_lifecycle_check check (
    (
      status = 'queued_preview'
      and started_at is null
      and previewed_at is null
      and committed_at is null
      and failed_at is null
      and plan_hash is null
    )
    or (
      status = 'staging'
      and started_at is not null
      and previewed_at is null
      and committed_at is null
      and failed_at is null
      and plan_hash is null
    )
    or (
      status in ('previewed', 'commit_queued', 'committing')
      and started_at is not null
      and previewed_at is not null
      and committed_at is null
      and failed_at is null
      and plan_hash is not null
    )
    or (
      status = 'committed'
      and started_at is not null
      and previewed_at is not null
      and committed_at is not null
      and failed_at is null
      and plan_hash is not null
    )
    or (
      status in ('failed', 'expired')
      and committed_at is null
      and failed_at is not null
      and failure_code is not null
    )
  )
);

create unique index dynamic_import_runs_actor_request_idx
  on app.dynamic_import_runs(created_by, client_request_id);
create unique index dynamic_import_runs_batch_mapping_idx
  on app.dynamic_import_runs(batch_id, mapping_revision_id);
create index dynamic_import_runs_worker_queue_idx
  on app.dynamic_import_runs(status, created_at)
  where status in ('queued_preview', 'staging', 'commit_queued', 'committing');
create index dynamic_import_runs_expiry_idx
  on app.dynamic_import_runs(expires_at)
  where status not in ('committed', 'expired');

create or replace function private.dynamic_import_reason_codes_valid(
  p_reason_codes text[]
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    p_reason_codes is not null
    and cardinality(p_reason_codes) between 0 and 32
    and coalesce((
      select bool_and(reason ~ '^[a-z][a-z0-9._-]{2,63}$')
      from unnest(p_reason_codes) reason
    ), true);
$$;

revoke all on function private.dynamic_import_reason_codes_valid(text[])
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_selected_shape_valid(
  p_selected_values jsonb
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    p_selected_values is not null
    and jsonb_typeof(p_selected_values) = 'object'
    and octet_length(p_selected_values::text) <= 65536
    and p_selected_values ?& array['sourceRow', 'fields', 'sizes', 'errors']
    and (
      select count(*)
      from jsonb_object_keys(p_selected_values)
    ) = 4;
$$;

revoke all on function private.dynamic_import_selected_shape_valid(jsonb)
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_resolved_variants_valid(
  p_resolved_variants jsonb
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    p_resolved_variants is not null
    and jsonb_typeof(p_resolved_variants) = 'object'
    and (select count(*) from jsonb_object_keys(p_resolved_variants)) <= 64
    and not exists(
      select 1
      from jsonb_each(p_resolved_variants) entry
      where entry.key !~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        or (
          jsonb_typeof(entry.value) <> 'null'
          and (
            jsonb_typeof(entry.value) <> 'string'
            or entry.value #>> '{}' !~
              '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          )
        )
    );
$$;

revoke all on function private.dynamic_import_resolved_variants_valid(jsonb)
from public, anon, authenticated, service_role;

create table app.dynamic_import_row_results (
  run_id uuid not null references app.dynamic_import_runs(id) on delete restrict,
  source_row integer not null check (source_row between 2 and 10001),
  outcome app.dynamic_import_row_outcome not null,
  blocking boolean not null,
  reason_codes text[] not null default '{}'::text[],
  change_count integer not null default 0 check (change_count between 0 and 100),
  conflict_count integer not null default 0 check (conflict_count between 0 and 64),
  protected_count integer not null default 0 check (protected_count between 0 and 64),
  created_at timestamptz not null default timezone('utc', now()),
  primary key (run_id, source_row),
  constraint dynamic_import_row_results_reasons_check check (
    private.dynamic_import_reason_codes_valid(reason_codes)
  )
);

create index dynamic_import_row_results_filter_idx
  on app.dynamic_import_row_results(run_id, outcome, source_row);

create table private.dynamic_import_selected_rows (
  run_id uuid not null references app.dynamic_import_runs(id) on delete restrict,
  source_row integer not null check (source_row between 2 and 10001),
  selected_values jsonb not null,
  row_hash text not null check (row_hash ~ '^[0-9a-f]{64}$'),
  identity_key_hash text check (
    identity_key_hash is null or identity_key_hash ~ '^[0-9a-f]{64}$'
  ),
  expires_at timestamptz not null,
  created_at timestamptz not null default timezone('utc', now()),
  primary key (run_id, source_row),
  constraint dynamic_import_selected_rows_shape_check check (
    private.dynamic_import_selected_shape_valid(selected_values)
  )
);

create index dynamic_import_selected_rows_identity_idx
  on private.dynamic_import_selected_rows(run_id, identity_key_hash)
  where identity_key_hash is not null;
create index dynamic_import_selected_rows_expiry_idx
  on private.dynamic_import_selected_rows(expires_at);

create table private.dynamic_import_selected_identity_keys (
  run_id uuid not null,
  source_row integer not null,
  identity_key_hash text not null check (
    identity_key_hash ~ '^[0-9a-f]{64}$'
  ),
  primary key (run_id, source_row, identity_key_hash),
  foreign key (run_id, source_row)
    references private.dynamic_import_selected_rows(run_id, source_row)
    on delete cascade
);

create index dynamic_import_selected_identity_lookup_idx
  on private.dynamic_import_selected_identity_keys(
    identity_key_hash,
    run_id,
    source_row
  );

create table private.dynamic_import_row_plans (
  run_id uuid not null,
  source_row integer not null,
  matched_member_id uuid references app.members(id) on delete restrict,
  state_hash text not null check (state_hash ~ '^[0-9a-f]{64}$'),
  analysis_hash text not null check (analysis_hash ~ '^[0-9a-f]{64}$'),
  resolved_variants jsonb not null default '{}'::jsonb check (
    private.dynamic_import_resolved_variants_valid(resolved_variants)
  ),
  primary key (run_id, source_row),
  foreign key (run_id, source_row)
    references app.dynamic_import_row_results(run_id, source_row)
    on delete restrict
);

create table private.dynamic_import_run_leases (
  run_id uuid primary key references app.dynamic_import_runs(id) on delete restrict,
  claim_token uuid not null unique,
  generation integer not null check (generation > 0),
  claimed_at timestamptz not null,
  expires_at timestamptz not null,
  constraint dynamic_import_run_leases_expiry_check check (expires_at > claimed_at)
);

alter table app.dynamic_import_runs enable row level security;
alter table app.dynamic_import_row_results enable row level security;
alter table private.dynamic_import_selected_rows enable row level security;
alter table private.dynamic_import_selected_identity_keys enable row level security;
alter table private.dynamic_import_row_plans enable row level security;
alter table private.dynamic_import_run_leases enable row level security;

create policy "administrators can read own dynamic import runs"
on app.dynamic_import_runs
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
  and created_by = auth.uid()
);

create policy "administrators can read own dynamic import row results"
on app.dynamic_import_row_results
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
  and exists(
    select 1
    from app.dynamic_import_runs run
    where run.id = run_id
      and run.created_by = auth.uid()
  )
);

revoke all on table app.dynamic_import_runs
from public, anon, authenticated, service_role;
revoke all on table app.dynamic_import_row_results
from public, anon, authenticated, service_role;
revoke all on table private.dynamic_import_selected_rows
from public, anon, authenticated, service_role;
revoke all on table private.dynamic_import_selected_identity_keys
from public, anon, authenticated, service_role;
revoke all on table private.dynamic_import_row_plans
from public, anon, authenticated, service_role;
revoke all on table private.dynamic_import_run_leases
from public, anon, authenticated, service_role;
grant select on table app.dynamic_import_runs to authenticated;
grant select on table app.dynamic_import_row_results to authenticated;

create or replace function private.normalize_import_member_match(p_value text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select lower(
    btrim(
      regexp_replace(
        normalize(coalesce(p_value, ''), NFKC),
        '[[:space:]]+',
        ' ',
        'g'
      )
    )
  );
$$;

revoke all on function private.normalize_import_member_match(text)
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_member_name_key(
  p_first_name text,
  p_insertion text,
  p_last_name text
)
returns text
language sql
immutable
set search_path = private, pg_temp
as $$
  select private.normalize_import_member_match(
    concat_ws(' ', p_first_name, p_insertion, p_last_name)
  );
$$;

revoke all on function private.dynamic_import_member_name_key(text, text, text)
from public, anon, authenticated, service_role;

create index members_dynamic_import_name_key_idx
  on app.members(
    private.dynamic_import_member_name_key(first_name, insertion, last_name)
  );
create index member_sensitive_identity_dob_lookup_idx
  on private.member_sensitive_identity(date_of_birth, member_id)
  where date_of_birth is not null;

create or replace function private.dynamic_import_identity_key_hashes(p_fields jsonb)
returns text[]
language plpgsql
immutable
set search_path = private, extensions, pg_temp
as $$
declare
  external_id text := nullif(p_fields->>'external_member_id', '');
  first_name text := nullif(p_fields->>'first_name', '');
  insertion text := coalesce(p_fields->>'insertion', '');
  last_name text := nullif(p_fields->>'last_name', '');
  email text := nullif(p_fields->>'email', '');
  date_of_birth text := nullif(p_fields->>'date_of_birth', '');
  external_hash text;
  compound_hash text;
  result text[] := array[]::text[];
begin
  if external_id is not null then
    external_hash := encode(
      extensions.digest(
        convert_to(
          'external:' || upper(btrim(normalize(external_id, NFKC))),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    );
    result := array_append(result, external_hash);
  end if;

  if first_name is not null
    and last_name is not null
    and (email is not null or date_of_birth is not null)
  then
    compound_hash := encode(
      extensions.digest(
        convert_to(
          concat_ws(
            ':',
            'compound',
            private.dynamic_import_member_name_key(
              first_name, insertion, last_name
            ),
            case
              when date_of_birth is null
                then private.normalize_import_member_match(coalesce(email, ''))
              else ''
            end,
            coalesce(date_of_birth, '')
          ),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    );
    if compound_hash is distinct from external_hash then
      result := array_append(result, compound_hash);
    end if;
  end if;

  return result;
end;
$$;

revoke all on function private.dynamic_import_identity_key_hashes(jsonb)
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_identity_key_hash(p_fields jsonb)
returns text
language sql
immutable
set search_path = private, pg_temp
as $$
  select (private.dynamic_import_identity_key_hashes(p_fields))[1];
$$;

revoke all on function private.dynamic_import_identity_key_hash(jsonb)
from public, anon, authenticated, service_role;

alter table private.dynamic_import_selected_rows
  add constraint dynamic_import_selected_identity_hash_consistency_check
  check (
    identity_key_hash is not distinct from
      private.dynamic_import_identity_key_hash(selected_values->'fields')
  );

create or replace function private.sync_dynamic_import_selected_identity_keys()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  delete from private.dynamic_import_selected_identity_keys identity_key
  where identity_key.run_id = new.run_id
    and identity_key.source_row = new.source_row;

  insert into private.dynamic_import_selected_identity_keys(
    run_id,
    source_row,
    identity_key_hash
  )
  select new.run_id, new.source_row, key_hash
  from unnest(
    private.dynamic_import_identity_key_hashes(new.selected_values->'fields')
  ) key_hash;
  return new;
end;
$$;

revoke all on function private.sync_dynamic_import_selected_identity_keys()
from public, anon, authenticated, service_role;

create trigger dynamic_import_selected_identity_keys_sync
after insert or update of selected_values, identity_key_hash
on private.dynamic_import_selected_rows
for each row execute function private.sync_dynamic_import_selected_identity_keys();

create or replace function private.dynamic_import_selected_row_valid(
  p_mapping jsonb,
  p_row jsonb,
  p_expected_source_row integer
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  field_entry record;
  size_entry record;
  error_value jsonb;
  source_row integer;
begin
  if jsonb_typeof(p_mapping) <> 'array'
    or jsonb_typeof(p_row) <> 'object'
    or octet_length(p_row::text) > 65536
    or not (p_row ?& array['sourceRow', 'fields', 'sizes', 'errors'])
    or (select count(*) from jsonb_object_keys(p_row)) <> 4
    or jsonb_typeof(p_row->'fields') <> 'object'
    or jsonb_typeof(p_row->'sizes') <> 'object'
    or jsonb_typeof(p_row->'errors') <> 'array'
    or jsonb_array_length(p_row->'errors') > 32
  then
    return false;
  end if;

  begin
    source_row := (p_row->>'sourceRow')::integer;
  exception when others then
    return false;
  end;
  if source_row <> p_expected_source_row
    or to_jsonb(source_row) is distinct from p_row->'sourceRow'
  then
    return false;
  end if;

  for field_entry in select key, value from jsonb_each(p_row->'fields')
  loop
    if not exists(
      select 1
      from jsonb_array_elements(p_mapping) entry
      where entry #>> '{target,kind}' = 'member_field'
        and entry #>> '{target,field}' = field_entry.key
    ) then
      return false;
    end if;

    if field_entry.key = 'active_for_season' then
      if jsonb_typeof(field_entry.value) <> 'boolean' then return false; end if;
    elsif jsonb_typeof(field_entry.value) <> 'string'
      or length(field_entry.value #>> '{}') not between 1 and (
        case
          when field_entry.key = 'email' then 320
          when field_entry.key = 'insertion' then 80
          else 120
        end
      )
      or field_entry.value #>> '{}' ~ '[[:cntrl:]]'
      or field_entry.value #>> '{}' ~ '^[-=+@]'
    then
      return false;
    end if;

    if field_entry.key = 'date_of_birth' and (
      field_entry.value #>> '{}' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or (field_entry.value #>> '{}')::date not between date '1900-01-01' and current_date
    ) then
      return false;
    end if;
    if field_entry.key = 'gender'
      and field_entry.value #>> '{}' not in ('male', 'female', 'other', 'unknown')
    then
      return false;
    end if;
  end loop;

  for size_entry in select key, value from jsonb_each(p_row->'sizes')
  loop
    if size_entry.key !~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or jsonb_typeof(size_entry.value) <> 'string'
      or length(size_entry.value #>> '{}') not between 1 and 160
      or size_entry.value #>> '{}' ~ '[[:cntrl:]]'
      or size_entry.value #>> '{}' ~ '^[-=+@]'
      or not exists(
        select 1
        from jsonb_array_elements(p_mapping) entry
        where entry #>> '{target,kind}' = 'product_size'
          and entry #>> '{target,articleId}' = size_entry.key
      )
    then
      return false;
    end if;
  end loop;

  for error_value in select value from jsonb_array_elements(p_row->'errors')
  loop
    if jsonb_typeof(error_value) <> 'string'
      or error_value #>> '{}' !~ '^[a-z][a-z0-9._-]{2,63}$'
    then
      return false;
    end if;
  end loop;
  return true;
exception
  when invalid_text_representation or datetime_field_overflow then
    return false;
end;
$$;

revoke all on function private.dynamic_import_selected_row_valid(jsonb, jsonb, integer)
from public, anon, authenticated, service_role;

create or replace function app.begin_dynamic_import_dry_run(
  p_run_id uuid,
  p_batch_id uuid,
  p_mapping_revision integer,
  p_client_request_id uuid,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  target_batch app.import_batches%rowtype;
  target_mapping app.import_mapping_revisions%rowtype;
  existing app.dynamic_import_runs%rowtype;
begin
  actor := private.require_dynamic_import_admin();
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_run_id is null
    or p_batch_id is null
    or p_mapping_revision is null
    or p_mapping_revision < 1
    or p_client_request_id is null
    or p_request_hash is null
    or p_request_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception 'DYNAMIC_IMPORT_DRY_RUN_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-run:' || actor::text || ':' || p_client_request_id::text,
      0
    )
  );

  select * into existing
  from app.dynamic_import_runs run
  where run.created_by = actor
    and run.client_request_id = p_client_request_id
  for update;
  if found then
    if existing.request_hash <> p_request_hash
      or existing.batch_id <> p_batch_id
    then
      raise exception 'DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'runId', existing.id,
      'batchId', existing.batch_id,
      'status', existing.status::text,
      'reused', true
    );
  end if;

  select * into target_batch
  from app.import_batches batch
  where batch.id = p_batch_id
    and batch.actor_user_id = actor
    and batch.schema_version = 2
  for update;

  if not found
    or target_batch.dynamic_status <> 'uploaded'
    or target_batch.active_mapping_revision_id is null
    or target_batch.expires_at <= timezone('utc', now()) + interval '10 minutes'
    or not exists(
      select 1
      from private.import_staging_payloads payload
      where payload.batch_id = target_batch.id
        and payload.expires_at = target_batch.expires_at
    )
    or not exists(
      select 1
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
        and season.id = target_batch.season_id
        and season.status = 'open'
    )
  then
    raise exception 'DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  select * into target_mapping
  from app.import_mapping_revisions mapping_revision
  where mapping_revision.id = target_batch.active_mapping_revision_id
    and mapping_revision.batch_id = target_batch.id
    and mapping_revision.season_id = target_batch.season_id
    and mapping_revision.revision = p_mapping_revision;
  if not found then
    raise exception 'DYNAMIC_IMPORT_REVISION_CHANGED' using errcode = '40001';
  end if;
  if target_mapping.catalog_hash is distinct from
    private.dynamic_import_catalog_hash(target_batch.season_id)
  then
    raise exception 'DYNAMIC_IMPORT_CATALOG_CHANGED' using errcode = '40001';
  end if;

  insert into app.dynamic_import_runs(
    id,
    batch_id,
    mapping_revision_id,
    season_id,
    created_by,
    client_request_id,
    request_hash,
    source_row_count,
    expires_at
  )
  values(
    p_run_id,
    target_batch.id,
    target_mapping.id,
    target_batch.season_id,
    actor,
    p_client_request_id,
    p_request_hash,
    target_batch.source_row_count,
    target_batch.expires_at
  )
  returning * into existing;

  update app.import_batches
  set dynamic_status = 'processing',
      failure_code = null
  where id = target_batch.id;

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
    'members.import.dry_run.queued',
    'import_batch',
    target_batch.id,
    jsonb_build_object(
      'runId', existing.id,
      'mappingRevision', target_mapping.revision,
      'rowCount', existing.source_row_count
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'runId', existing.id,
    'batchId', existing.batch_id,
    'status', existing.status::text,
    'reused', false
  );
exception
  when unique_violation then
    select * into existing
    from app.dynamic_import_runs run
    where run.batch_id = p_batch_id
      and run.mapping_revision_id = target_mapping.id;
    if found and existing.created_by = actor then
      return jsonb_build_object(
        'runId', existing.id,
        'batchId', existing.batch_id,
        'status', existing.status::text,
        'reused', true
      );
    end if;
    raise exception 'DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.get_dynamic_import_dry_run(
  p_run_id uuid,
  p_outcome app.dynamic_import_row_outcome default null,
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
  actor uuid;
  target app.dynamic_import_runs%rowtype;
begin
  actor := private.require_dynamic_import_admin();
  if p_run_id is null
    or p_offset is null
    or p_offset < 0
    or p_limit is null
    or p_limit not between 1 and 100
  then
    raise exception 'DYNAMIC_IMPORT_DRY_RUN_QUERY_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
    and run.created_by = actor;
  if not found then
    raise exception 'DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'runId', target.id,
    'batchId', target.batch_id,
    'seasonId', target.season_id,
    'status', target.status::text,
    'sourceRowCount', target.source_row_count,
    'processedRowCount', greatest(0, target.next_analysis_source_row - 2),
    'committedRowCount', greatest(0, target.next_commit_source_row - 2),
    'outcomeCounts', target.outcome_counts,
    'hasBlockers', target.has_blockers,
    'planHash', target.plan_hash,
    'expiresAt', target.expires_at,
    'previewedAt', target.previewed_at,
    'committedAt', target.committed_at,
    'failureCode', target.failure_code,
    'offset', p_offset,
    'limit', p_limit,
    'filteredTotal', (
      select count(*)
      from app.dynamic_import_row_results result
      where result.run_id = target.id
        and (p_outcome is null or result.outcome = p_outcome)
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'sourceRow', page.source_row,
        'outcome', page.outcome::text,
        'blocking', page.blocking,
        'reasonCodes', to_jsonb(page.reason_codes),
        'changeCount', page.change_count,
        'conflictCount', page.conflict_count,
        'protectedCount', page.protected_count
      ) order by page.source_row)
      from (
        select *
        from app.dynamic_import_row_results result
        where result.run_id = target.id
          and (p_outcome is null or result.outcome = p_outcome)
        order by result.source_row
        offset p_offset
        limit p_limit
      ) page
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.claim_dynamic_import_run(
  p_claim_token uuid,
  p_lease_seconds integer default 55
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target app.dynamic_import_runs%rowtype;
  generation integer;
  claimed timestamptz := timezone('utc', now());
  target_mapping app.import_mapping_revisions%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if p_claim_token is null
    or p_lease_seconds is null
    or p_lease_seconds not between 15 and 60
  then
    raise exception 'DYNAMIC_IMPORT_CLAIM_INVALID' using errcode = '22023';
  end if;
  if not private.dynamic_import_enabled() then
    return jsonb_build_object('job', null);
  end if;

  select run.* into target
  from app.dynamic_import_runs run
  left join private.dynamic_import_run_leases lease on lease.run_id = run.id
  where (
      run.status = 'queued_preview'
      or (run.status = 'staging' and (lease.run_id is null or lease.expires_at <= claimed))
      or run.status = 'commit_queued'
      or (run.status = 'committing' and (lease.run_id is null or lease.expires_at <= claimed))
    )
    and run.expires_at > claimed
  order by
    case run.status
      when 'commit_queued' then 1
      when 'committing' then 2
      when 'staging' then 3
      else 4
    end,
    run.created_at,
    run.id
  for update of run skip locked
  limit 1;

  if not found then
    return jsonb_build_object('job', null);
  end if;

  select * into target_mapping
  from app.import_mapping_revisions mapping_revision
  where mapping_revision.id = target.mapping_revision_id;
  if not found then
    raise exception 'DYNAMIC_IMPORT_MAPPING_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into private.dynamic_import_run_leases(
    run_id,
    claim_token,
    generation,
    claimed_at,
    expires_at
  )
  values(
    target.id,
    p_claim_token,
    1,
    claimed,
    claimed + make_interval(secs => p_lease_seconds)
  )
  on conflict (run_id) do update
  set claim_token = excluded.claim_token,
      generation = private.dynamic_import_run_leases.generation + 1,
      claimed_at = excluded.claimed_at,
      expires_at = excluded.expires_at
  returning private.dynamic_import_run_leases.generation into generation;

  update app.dynamic_import_runs
  set status = case
        when target.status in ('commit_queued', 'committing')
          then 'committing'::app.dynamic_import_run_status
        else 'staging'::app.dynamic_import_run_status
      end,
      started_at = coalesce(started_at, claimed),
      attempt_count = attempt_count + 1
  where id = target.id
  returning * into target;

  return jsonb_build_object(
    'job', jsonb_build_object(
      'runId', target.id,
      'batchId', target.batch_id,
      'actorId', target.created_by,
      'seasonId', target.season_id,
      'mappingRevisionId', target.mapping_revision_id,
      'mappingRevision', target_mapping.revision,
      'mapping', target_mapping.mapping,
      'mappingHash', target_mapping.mapping_hash,
      'headerHash', target_mapping.header_hash,
      'catalogHash', target_mapping.catalog_hash,
      'catalogCurrent',
        target_mapping.catalog_hash =
          private.dynamic_import_catalog_hash(target.season_id),
      'policy', target_mapping.policy,
      'phase', case when target.status = 'committing' then 'commit' else 'preview' end,
      'generation', generation,
      'nextSourceRow',
        case
          when target.status = 'committing' then target.next_commit_source_row
          else target.next_source_row
        end,
      'nextAnalysisSourceRow', target.next_analysis_source_row,
      'sourceRowCount', target.source_row_count,
      'expiresAt', target.expires_at
    )
  );
end;
$$;

create or replace function app.stage_dynamic_import_rows(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer,
  p_start_source_row integer,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
#variable_conflict use_variable
declare
  target app.dynamic_import_runs%rowtype;
  target_mapping jsonb;
  lease private.dynamic_import_run_leases%rowtype;
  row_value jsonb;
  row_number integer;
  row_digest text;
  existing_hash text;
  row_count integer;
  next_row integer;
  reused boolean := false;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_run_id is null
    or p_claim_token is null
    or p_generation is null
    or p_generation < 1
    or p_start_source_row is null
    or p_start_source_row < 2
    or jsonb_typeof(p_rows) <> 'array'
    or jsonb_array_length(p_rows) not between 1 and 250
  then
    raise exception 'DYNAMIC_IMPORT_CHUNK_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
  for update;
  select * into lease
  from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = p_run_id
  for update;
  if not found
    or target.status <> 'staging'
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= timezone('utc', now())
    or target.expires_at <= timezone('utc', now())
  then
    raise exception 'DYNAMIC_IMPORT_LEASE_CONFLICT' using errcode = '40001';
  end if;

  select mapping_revision.mapping into target_mapping
  from app.import_mapping_revisions mapping_revision
  where mapping_revision.id = target.mapping_revision_id;
  if target_mapping is null then
    raise exception 'DYNAMIC_IMPORT_MAPPING_NOT_FOUND' using errcode = 'P0002';
  end if;

  row_count := jsonb_array_length(p_rows);
  if p_start_source_row + row_count - 1 > target.source_row_count + 1 then
    raise exception 'DYNAMIC_IMPORT_CHUNK_RANGE_INVALID' using errcode = '22023';
  end if;
  if p_start_source_row > target.next_source_row then
    raise exception 'DYNAMIC_IMPORT_CHUNK_ORDER_CONFLICT' using errcode = '40001';
  end if;

  row_number := p_start_source_row;
  for row_value in select value from jsonb_array_elements(p_rows)
  loop
    if not private.dynamic_import_selected_row_valid(
      target_mapping,
      row_value,
      row_number
    ) then
      raise exception 'DYNAMIC_IMPORT_SELECTED_ROW_INVALID' using errcode = '22023';
    end if;
    row_digest := encode(
      extensions.digest(convert_to(row_value::text, 'UTF8'), 'sha256'),
      'hex'
    );

    select selected.row_hash into existing_hash
    from private.dynamic_import_selected_rows selected
    where selected.run_id = target.id
      and selected.source_row = row_number;
    if found then
      if existing_hash <> row_digest then
        raise exception 'DYNAMIC_IMPORT_CHUNK_REPLAY_CONFLICT' using errcode = '23505';
      end if;
      reused := true;
    else
      if row_number < target.next_source_row then
        raise exception 'DYNAMIC_IMPORT_CHUNK_REPLAY_MISSING' using errcode = '40001';
      end if;
      insert into private.dynamic_import_selected_rows(
        run_id,
        source_row,
        selected_values,
        row_hash,
        identity_key_hash,
        expires_at
      )
      values(
        target.id,
        row_number,
        row_value,
        row_digest,
        private.dynamic_import_identity_key_hash(row_value->'fields'),
        target.expires_at
      );
    end if;
    row_number := row_number + 1;
  end loop;

  next_row := greatest(target.next_source_row, p_start_source_row + row_count);
  update app.dynamic_import_runs
  set next_source_row = next_row
  where id = target.id;
  update app.import_batches
  set next_source_row = next_row
  where id = target.batch_id;
  update private.dynamic_import_run_leases
  set expires_at = timezone('utc', now()) + interval '55 seconds'
  where run_id = target.id;
  if next_row = target.source_row_count + 2 then
    -- The selected projection is complete. From this point onward analysis and
    -- commit no longer need ignored source columns or the encrypted raw upload.
    delete from private.import_staging_payloads payload
    where payload.batch_id = target.batch_id;
  end if;

  return jsonb_build_object(
    'runId', target.id,
    'accepted', row_count,
    'nextSourceRow', next_row,
    'complete', next_row = target.source_row_count + 2,
    'reused', reused
  );
end;
$$;

create or replace function private.dynamic_import_member_state_hash(
  p_member_id uuid,
  p_season_id uuid,
  p_articles uuid[]
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          '|',
          coalesce((
            select concat_ws(
              ':',
              member.id,
              member.updated_at
            )
            from app.members member
            where member.id = p_member_id
          ), 'missing'),
          coalesce((
            select concat_ws(
              ':',
              identity_row.member_id,
              identity_row.updated_at
            )
            from private.member_sensitive_identity identity_row
            where identity_row.member_id = p_member_id
          ), ''),
          coalesce((
            select concat_ws(
              ':',
              member_season.id,
              member_season.participation_status,
              member_season.reconciliation_status,
              member_season.updated_at
            )
            from app.member_seasons member_season
            where member_season.member_id = p_member_id
              and member_season.season_id = p_season_id
          ), ''),
          coalesce((
            select string_agg(
              concat_ws(
                ':',
                size.article_id,
                size.article_variant_id,
                size.selection_status,
                size.selection_source,
                size.updated_at
              ),
              ','
              order by size.article_id
            )
            from app.member_article_sizes size
            where size.member_id = p_member_id
              and size.season_id = p_season_id
              and size.article_id = any(p_articles)
          ), ''),
          coalesce((
            select string_agg(
              concat_ws(
                ':',
                external_identity.id,
                external_identity.issuer,
                external_identity.is_primary,
                external_identity.verified_at
              ),
              ','
              order by external_identity.issuer, external_identity.id
            )
            from app.member_external_identities external_identity
            where external_identity.member_id = p_member_id
          ), '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

revoke all on function private.dynamic_import_member_state_hash(uuid, uuid, uuid[])
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_analyze_row(
  p_run_id uuid,
  p_source_row integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
#variable_conflict use_variable
declare
  target_run app.dynamic_import_runs%rowtype;
  selected private.dynamic_import_selected_rows%rowtype;
  fields jsonb;
  sizes jsonb;
  errors jsonb;
  external_id text;
  first_name text;
  insertion text;
  last_name text;
  email text;
  incoming_dob date;
  incoming_full_name text;
  candidate_count integer := 0;
  candidate_id uuid;
  matched_member app.members%rowtype;
  existing_dob date;
  existing_season app.member_seasons%rowtype;
  identity_key_count integer := 0;
  reason_codes text[] := array[]::text[];
  blocking boolean := false;
  change_count integer := 0;
  conflict_count integer := 0;
  protected_count integer := 0;
  size_entry record;
  article_ids uuid[] := array[]::uuid[];
  article_id uuid;
  normalized_size text;
  variant_id uuid;
  variant_count integer;
  current_size app.member_article_sizes%rowtype;
  outcome app.dynamic_import_row_outcome;
  state_hash text;
  analysis_hash text;
  usable_email boolean;
  compound_candidate_id uuid;
  cross_candidate_count integer := 0;
  resolved_variants jsonb := '{}'::jsonb;
begin
  select * into target_run
  from app.dynamic_import_runs run
  where run.id = p_run_id;
  select * into selected
  from private.dynamic_import_selected_rows selected_row
  where selected_row.run_id = p_run_id
    and selected_row.source_row = p_source_row;
  if target_run.id is null or selected.run_id is null then
    raise exception 'DYNAMIC_IMPORT_ROW_NOT_FOUND' using errcode = 'P0002';
  end if;

  fields := selected.selected_values->'fields';
  sizes := selected.selected_values->'sizes';
  errors := selected.selected_values->'errors';
  external_id := nullif(fields->>'external_member_id', '');
  first_name := nullif(fields->>'first_name', '');
  insertion := nullif(fields->>'insertion', '');
  last_name := nullif(fields->>'last_name', '');
  email := nullif(fields->>'email', '');
  incoming_dob := nullif(fields->>'date_of_birth', '')::date;
  usable_email := email is not null and private.parent_access_email_valid(email);
  incoming_full_name := private.dynamic_import_member_name_key(
    first_name, insertion, last_name
  );

  select count(distinct duplicate_key.source_row)
  into identity_key_count
  from private.dynamic_import_selected_identity_keys current_key
  join private.dynamic_import_selected_identity_keys duplicate_key
    on duplicate_key.run_id = current_key.run_id
    and duplicate_key.identity_key_hash = current_key.identity_key_hash
  where current_key.run_id = target_run.id
    and current_key.source_row = selected.source_row;

  if jsonb_array_length(errors) > 0 then
    reason_codes := array(
      select distinct value #>> '{}'
      from jsonb_array_elements(errors)
      order by value #>> '{}'
    );
    blocking := true;
  elsif identity_key_count > 1 then
    reason_codes := array['duplicate_source_identity'];
    blocking := true;
  else
    if external_id is not null then
      select identity_row.member_id into candidate_id
      from app.member_external_identities identity_row
      where identity_row.issuer = 'sportlink'
        and identity_row.external_id_normalized = upper(btrim(external_id));

      if candidate_id is null and first_name is not null and last_name is not null
        and (incoming_dob is not null or usable_email)
      then
        if incoming_dob is not null then
          select count(*), (array_agg(member.id order by member.id))[1]
          into candidate_count, compound_candidate_id
          from app.members member
          join private.member_sensitive_identity sensitive
            on sensitive.member_id = member.id
          where private.dynamic_import_member_name_key(
              member.first_name, member.insertion, member.last_name
            ) = incoming_full_name
            and sensitive.date_of_birth = incoming_dob;
        else
          select count(*), (array_agg(member.id order by member.id))[1]
          into candidate_count, compound_candidate_id
          from app.members member
          where private.dynamic_import_member_name_key(
              member.first_name, member.insertion, member.last_name
            ) = incoming_full_name
            and lower(member.email) = lower(email);
        end if;
        if candidate_count > 0 then
          reason_codes := array['external_identity_requires_review'];
          blocking := true;
        end if;
      end if;
    else
      if first_name is null
        or last_name is null
        or (incoming_dob is null and not usable_email)
      then
        reason_codes := array['identity_insufficient'];
        blocking := true;
      elsif incoming_dob is not null then
        select count(*), (array_agg(member.id order by member.id))[1]
        into candidate_count, candidate_id
        from app.members member
        join private.member_sensitive_identity sensitive
          on sensitive.member_id = member.id
        where private.dynamic_import_member_name_key(
            member.first_name, member.insertion, member.last_name
          ) = incoming_full_name
          and sensitive.date_of_birth = incoming_dob;
      else
        select count(*), (array_agg(member.id order by member.id))[1]
        into candidate_count, candidate_id
        from app.members member
        where private.dynamic_import_member_name_key(
            member.first_name, member.insertion, member.last_name
          ) = incoming_full_name
          and lower(member.email) = lower(email);
      end if;

      if not blocking and candidate_count > 1 then
        reason_codes := array['identity_ambiguous'];
        candidate_id := null;
        blocking := true;
      end if;
    end if;
  end if;

  if candidate_id is not null and not blocking then
    if external_id is not null
      and first_name is not null
      and last_name is not null
      and (incoming_dob is not null or usable_email)
    then
      if incoming_dob is not null then
        select count(*) into cross_candidate_count
        from app.members member
        join private.member_sensitive_identity sensitive
          on sensitive.member_id = member.id
        where member.id <> candidate_id
          and private.dynamic_import_member_name_key(
            member.first_name, member.insertion, member.last_name
          ) = incoming_full_name
          and sensitive.date_of_birth = incoming_dob;
      else
        select count(*) into cross_candidate_count
        from app.members member
        where member.id <> candidate_id
          and private.dynamic_import_member_name_key(
            member.first_name, member.insertion, member.last_name
          ) = incoming_full_name
          and lower(member.email) = lower(email);
      end if;
      if cross_candidate_count > 0 then
        reason_codes := array_append(reason_codes, 'identity_cross_match');
        blocking := true;
      end if;
    end if;

    select * into matched_member
    from app.members member
    where member.id = candidate_id;
    select sensitive.date_of_birth into existing_dob
    from private.member_sensitive_identity sensitive
    where sensitive.member_id = candidate_id;

    if incoming_dob is not null
      and existing_dob is not null
      and incoming_dob <> existing_dob
    then
      reason_codes := array_append(reason_codes, 'date_of_birth_mismatch');
      blocking := true;
    elsif incoming_dob is not null and existing_dob is null then
      change_count := change_count + 1;
    end if;
    if incoming_dob is not null
      and email is not null
      and matched_member.email is not null
      and lower(email) <> lower(matched_member.email)
      and external_id is null
    then
      reason_codes := array_append(reason_codes, 'email_identity_mismatch');
      blocking := true;
    end if;

    if not blocking then
      if fields ? 'first_name'
        and matched_member.first_name is distinct from first_name
      then change_count := change_count + 1; end if;
      if fields ? 'insertion'
        and matched_member.insertion is distinct from insertion
      then change_count := change_count + 1; end if;
      if fields ? 'last_name'
        and matched_member.last_name is distinct from last_name
      then change_count := change_count + 1; end if;
      if fields ? 'email'
        and matched_member.email is distinct from email
      then change_count := change_count + 1; end if;
      if fields ? 'gender'
        and matched_member.gender::text is distinct from fields->>'gender'
      then change_count := change_count + 1; end if;

      select * into existing_season
      from app.member_seasons member_season
      where member_season.member_id = candidate_id
        and member_season.season_id = target_run.season_id;
      if not found then
        change_count := change_count + 1;
      else
        if fields ? 'team'
          and existing_season.team_name is distinct from fields->>'team'
        then change_count := change_count + 1; end if;
        if fields ? 'active_for_season'
          and existing_season.participation_status::text is distinct from
            (
              case
                when (fields->>'active_for_season')::boolean then 'active'
                else 'inactive'
              end
            )
        then change_count := change_count + 1; end if;
      end if;
    end if;
  elsif not blocking then
    if first_name is null then
      reason_codes := array_append(reason_codes, 'missing_first_name');
      blocking := true;
    end if;
    if last_name is null then
      reason_codes := array_append(reason_codes, 'missing_last_name');
      blocking := true;
    end if;
    if nullif(fields->>'team', '') is null then
      reason_codes := array_append(reason_codes, 'missing_team');
      blocking := true;
    end if;
    if external_id is null
      and (incoming_dob is null or first_name is null or last_name is null)
      and not (usable_email and first_name is not null and last_name is not null)
    then
      reason_codes := array_append(reason_codes, 'identity_insufficient');
      blocking := true;
    end if;
    if not blocking then change_count := change_count + 1; end if;
  end if;

  for size_entry in select key, value from jsonb_each_text(sizes)
  loop
    article_id := size_entry.key::uuid;
    article_ids := array_append(article_ids, article_id);
    if blocking then continue; end if;

    normalized_size := private.normalize_size_match(size_entry.value);
    select
      count(distinct matched.variant_id),
      (array_agg(distinct matched.variant_id order by matched.variant_id))[1]
    into variant_count, variant_id
    from (
      select variant.id variant_id
      from app.article_variants variant
      where variant.article_id = article_id
        and variant.active
        and (
          private.normalize_size_match(variant.size) = normalized_size
          or (
            nullif(btrim(variant.sku), '') is not null
            and private.normalize_size_match(variant.sku) = normalized_size
          )
        )
      union
      select alias.article_variant_id
      from app.article_variant_aliases alias
      join app.article_variants variant
        on variant.id = alias.article_variant_id
        and variant.active
      where alias.article_id = article_id
        and alias.alias_normalized = normalized_size
    ) matched;
    resolved_variants := resolved_variants || jsonb_build_object(
      article_id::text,
      case when variant_count = 1 then to_jsonb(variant_id::text) else 'null'::jsonb end
    );

    if candidate_id is not null then
      select * into current_size
      from app.member_article_sizes size
      where size.member_id = candidate_id
        and size.season_id = target_run.season_id
        and size.article_id = article_id;
    else
      current_size := null;
    end if;

    if variant_count <> 1 then
      if current_size.member_id is not null
        and (
          current_size.selection_status in ('confirmed', 'change_requested', 'locked')
          or (
            current_size.selection_status = 'conflict'
            and current_size.selection_source <> 'import'
          )
        )
      then
        protected_count := protected_count + 1;
        reason_codes := array_append(reason_codes, 'confirmed_size_protected');
      else
        conflict_count := conflict_count + 1;
        reason_codes := array_append(reason_codes, 'unknown_size');
      end if;
    elsif current_size.member_id is not null
      and (
        current_size.selection_status in ('confirmed', 'change_requested', 'locked')
        or (
          current_size.selection_status = 'conflict'
          and current_size.selection_source <> 'import'
        )
      )
    then
      protected_count := protected_count + 1;
      reason_codes := array_append(reason_codes, 'confirmed_size_protected');
    elsif current_size.member_id is null
      or current_size.article_variant_id is distinct from variant_id
      or current_size.selection_status <> 'imported_unconfirmed'
      or current_size.selection_source <> 'import'
    then
      change_count := change_count + 1;
    end if;
  end loop;

  reason_codes := array(
    select distinct reason
    from unnest(reason_codes) reason
    order by reason
  );
  outcome := case
    when blocking and exists(
      select 1 from unnest(reason_codes) reason
      where reason like 'invalid_%'
        or reason in ('missing_first_name', 'missing_last_name', 'missing_team')
    ) then 'error'::app.dynamic_import_row_outcome
    when blocking then 'conflict'::app.dynamic_import_row_outcome
    when conflict_count > 0 then 'conflict'::app.dynamic_import_row_outcome
    when protected_count > 0 then 'protected'::app.dynamic_import_row_outcome
    when candidate_id is null then 'create'::app.dynamic_import_row_outcome
    when change_count > 0 then 'update'::app.dynamic_import_row_outcome
    else 'skip'::app.dynamic_import_row_outcome
  end;

  state_hash := case
    when candidate_id is null then encode(
      extensions.digest(
        convert_to('new:' || coalesce(selected.identity_key_hash, ''), 'UTF8'),
        'sha256'
      ),
      'hex'
    )
    else private.dynamic_import_member_state_hash(
      candidate_id,
      target_run.season_id,
      article_ids
    )
  end;
  analysis_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'outcome', outcome::text,
          'blocking', blocking,
          'reasonCodes', to_jsonb(reason_codes),
          'matchedMemberId', candidate_id,
          'stateHash', state_hash,
          'resolvedVariants', resolved_variants,
          'changeCount', change_count,
          'conflictCount', conflict_count,
          'protectedCount', protected_count
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  return jsonb_build_object(
    'outcome', outcome::text,
    'blocking', blocking,
    'reasonCodes', to_jsonb(reason_codes),
    'matchedMemberId', candidate_id,
    'stateHash', state_hash,
    'resolvedVariants', resolved_variants,
    'analysisHash', analysis_hash,
    'changeCount', change_count,
    'conflictCount', conflict_count,
    'protectedCount', protected_count
  );
end;
$$;

revoke all on function private.dynamic_import_analyze_row(uuid, integer)
from public, anon, authenticated, service_role;

create or replace function app.analyze_dynamic_import_chunk(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target app.dynamic_import_runs%rowtype;
  lease private.dynamic_import_run_leases%rowtype;
  target_mapping app.import_mapping_revisions%rowtype;
  source_row integer;
  end_source_row integer;
  analysis jsonb;
  processed integer := 0;
  next_row integer;
  article_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_run_id is null
    or p_claim_token is null
    or p_generation is null
    or p_generation < 1
    or p_limit is null
    or p_limit not between 1 and 250
  then
    raise exception 'DYNAMIC_IMPORT_ANALYSIS_CHUNK_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
  for update;
  select * into lease
  from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = p_run_id
  for update;
  if target.id is null
    or lease.run_id is null
    or target.status <> 'staging'
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= timezone('utc', now())
    or target.expires_at <= timezone('utc', now())
    or target.next_source_row <> target.source_row_count + 2
    or (
      select count(*)
      from private.dynamic_import_selected_rows selected
      where selected.run_id = target.id
    ) <> target.source_row_count
  then
    raise exception 'DYNAMIC_IMPORT_ANALYSIS_LEASE_CONFLICT' using errcode = '40001';
  end if;

  select * into target_mapping
  from app.import_mapping_revisions mapping_revision
  where mapping_revision.id = target.mapping_revision_id;
  if not found then
    raise exception 'DYNAMIC_IMPORT_MAPPING_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('catalog-season:' || target.season_id::text, 0)
  );
  for article_id in
    select distinct (entry #>> '{target,articleId}')::uuid
    from jsonb_array_elements(target_mapping.mapping) entry
    where entry #>> '{target,kind}' = 'product_size'
    order by (entry #>> '{target,articleId}')::uuid
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('catalog-variant:' || article_id::text, 0)
    );
  end loop;

  if target_mapping.catalog_hash is distinct from
      private.dynamic_import_catalog_hash(target.season_id)
    or not exists(
      select 1
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
        and season.id = target.season_id
        and season.status = 'open'
      for share of settings, season
    )
  then
    raise exception 'DYNAMIC_IMPORT_PREVIEW_STATE_DRIFT' using errcode = '40001';
  end if;

  source_row := target.next_analysis_source_row;
  end_source_row := least(
    target.source_row_count + 1,
    source_row + p_limit - 1
  );
  while source_row <= end_source_row
  loop
    analysis := private.dynamic_import_analyze_row(target.id, source_row);
    insert into app.dynamic_import_row_results(
      run_id,
      source_row,
      outcome,
      blocking,
      reason_codes,
      change_count,
      conflict_count,
      protected_count
    )
    values(
      target.id,
      source_row,
      (analysis->>'outcome')::app.dynamic_import_row_outcome,
      (analysis->>'blocking')::boolean,
      array(
        select value #>> '{}'
        from jsonb_array_elements(analysis->'reasonCodes')
      ),
      (analysis->>'changeCount')::integer,
      (analysis->>'conflictCount')::integer,
      (analysis->>'protectedCount')::integer
    );
    insert into private.dynamic_import_row_plans(
      run_id,
      source_row,
      matched_member_id,
      state_hash,
      analysis_hash,
      resolved_variants
    )
    values(
      target.id,
      source_row,
      nullif(analysis->>'matchedMemberId', '')::uuid,
      analysis->>'stateHash',
      analysis->>'analysisHash',
      analysis->'resolvedVariants'
    );
    processed := processed + 1;
    source_row := source_row + 1;
  end loop;

  next_row := target.next_analysis_source_row + processed;
  update app.dynamic_import_runs
  set next_analysis_source_row = next_row
  where id = target.id;
  update private.dynamic_import_run_leases
  set expires_at = timezone('utc', now()) + interval '55 seconds'
  where run_id = target.id;

  return jsonb_build_object(
    'runId', target.id,
    'processed', processed,
    'nextSourceRow', next_row,
    'complete', next_row = target.source_row_count + 2
  );
end;
$$;

create or replace function app.finalize_dynamic_import_dry_run(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target app.dynamic_import_runs%rowtype;
  lease private.dynamic_import_run_leases%rowtype;
  duplicate_member uuid;
  blocked_row record;
  counts jsonb;
  blockers boolean;
  calculated_plan_hash text;
  blocker_dedupe_key text;
  finished timestamptz := timezone('utc', now());
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_run_id is null or p_claim_token is null or p_generation is null then
    raise exception 'DYNAMIC_IMPORT_FINALIZE_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
  for update;
  select * into lease
  from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = p_run_id
  for update;
  if target.id is null
    or lease.run_id is null
    or target.status <> 'staging'
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= finished
    or target.expires_at <= finished
    or target.next_source_row <> target.source_row_count + 2
    or target.next_analysis_source_row <> target.source_row_count + 2
    or (
      select count(*)
      from private.dynamic_import_selected_rows selected
      where selected.run_id = target.id
    ) <> target.source_row_count
  then
    raise exception 'DYNAMIC_IMPORT_FINALIZE_CONFLICT' using errcode = '40001';
  end if;

  for duplicate_member in
    select plan.matched_member_id
    from private.dynamic_import_row_plans plan
    where plan.run_id = target.id
      and plan.matched_member_id is not null
    group by plan.matched_member_id
    having count(*) > 1
  loop
    update app.dynamic_import_row_results result
    set outcome = 'conflict',
        blocking = true,
        reason_codes = array(
          select distinct reason
          from unnest(result.reason_codes || array['duplicate_target_member']) reason
          order by reason
        )
    where result.run_id = target.id
      and exists(
        select 1
        from private.dynamic_import_row_plans plan
        where plan.run_id = result.run_id
          and plan.source_row = result.source_row
          and plan.matched_member_id = duplicate_member
      );
    update private.dynamic_import_row_plans plan
    set analysis_hash = encode(
      extensions.digest(
        convert_to(plan.analysis_hash || ':duplicate_target_member', 'UTF8'),
        'sha256'
      ),
      'hex'
    )
    where plan.run_id = target.id
      and plan.matched_member_id = duplicate_member;
  end loop;

  select jsonb_build_object(
    'create', count(*) filter (where outcome = 'create'),
    'update', count(*) filter (where outcome = 'update'),
    'skip', count(*) filter (where outcome = 'skip'),
    'protected', count(*) filter (where outcome = 'protected'),
    'conflict', count(*) filter (where outcome = 'conflict'),
    'error', count(*) filter (where outcome = 'error')
  ),
  bool_or(blocking)
  into counts, blockers
  from app.dynamic_import_row_results result
  where result.run_id = target.id;

  select encode(
    extensions.digest(
      convert_to(
        string_agg(
          plan.source_row::text || ':' || plan.analysis_hash,
          ','
          order by plan.source_row
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  into calculated_plan_hash
  from private.dynamic_import_row_plans plan
  where plan.run_id = target.id;

  for blocked_row in
    select result.source_row, result.reason_codes
    from app.dynamic_import_row_results result
    where result.run_id = target.id
      and result.blocking
    order by result.source_row
  loop
    blocker_dedupe_key := encode(
      extensions.digest(
        convert_to(
          'import-row-conflict:' || target.id::text || ':' ||
            blocked_row.source_row::text,
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    );
    perform private.open_action_item(
      'import_row_conflict',
      target.season_id,
      'import_batch',
      target.batch_id,
      'import_run',
      target.id,
      blocker_dedupe_key,
      'warning',
      'admin_only',
      coalesce(blocked_row.reason_codes[1], 'import_row_blocked'),
      jsonb_build_object(
        'runId', target.id,
        'batchId', target.batch_id,
        'sourceRow', blocked_row.source_row,
        'blocked', true
      ),
      null
    );
  end loop;

  update app.dynamic_import_runs
  set status = 'previewed',
      outcome_counts = counts,
      has_blockers = coalesce(blockers, false),
      plan_hash = calculated_plan_hash,
      previewed_at = finished
  where id = target.id;
  update app.import_batches
  set dynamic_status = 'previewed',
      status = 'preview',
      row_counts = counts || jsonb_build_object(
        'total', target.source_row_count,
        'blocking', coalesce((
          select count(*)
          from app.dynamic_import_row_results result
          where result.run_id = target.id and result.blocking
        ), 0)
      ),
      failure_code = null
  where id = target.batch_id;

  -- Once the selected projection and immutable plan exist, ignored source
  -- columns are no longer retained, even as ciphertext.
  delete from private.import_staging_payloads payload
  where payload.batch_id = target.batch_id;
  delete from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = target.id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    target.created_by,
    'members.import.dry_run.completed',
    'import_batch',
    target.batch_id,
    jsonb_build_object(
      'runId', target.id,
      'rowCount', target.source_row_count,
      'outcomeCounts', counts,
      'hasBlockers', coalesce(blockers, false)
    )
  );

  return jsonb_build_object(
    'runId', target.id,
    'status', 'previewed',
    'outcomeCounts', counts,
    'hasBlockers', coalesce(blockers, false),
    'planHash', calculated_plan_hash
  );
end;
$$;

create or replace function app.fail_dynamic_import_run(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer,
  p_failure_code text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target app.dynamic_import_runs%rowtype;
  lease private.dynamic_import_run_leases%rowtype;
  failed timestamptz := timezone('utc', now());
  failure_dedupe_key text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if p_run_id is null
    or p_claim_token is null
    or p_generation is null
    or p_generation < 1
    or p_failure_code is null
    or p_failure_code !~ '^[a-z0-9][a-z0-9._-]{0,63}$'
  then
    raise exception 'DYNAMIC_IMPORT_FAILURE_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
  for update;
  select * into lease
  from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = p_run_id
  for update;
  if target.id is null
    or lease.run_id is null
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= failed
    or target.expires_at <= failed
    or target.status not in ('staging', 'committing')
  then
    raise exception 'DYNAMIC_IMPORT_LEASE_CONFLICT' using errcode = '40001';
  end if;

  update app.dynamic_import_runs
  set status = 'failed',
      failure_code = p_failure_code,
      failed_at = failed
  where id = target.id;
  update app.import_batches
  set dynamic_status = 'failed',
      status = 'failed',
      failure_code = p_failure_code
  where id = target.batch_id;
  delete from private.dynamic_import_run_leases where run_id = target.id;

  failure_dedupe_key := encode(
    extensions.digest(
      convert_to('import-failure:' || target.id::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform private.open_action_item(
    'import_failure',
    target.season_id,
    'import_batch',
    target.batch_id,
    'import_run',
    target.id,
    failure_dedupe_key,
    'critical',
    'admin_only',
    p_failure_code,
    jsonb_build_object(
      'runId', target.id,
      'batchId', target.batch_id,
      'blocked', true
    ),
    failed + interval '1 hour'
  );

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    target.created_by,
    'members.import.processing.failed',
    'import_batch',
    target.batch_id,
    jsonb_build_object('runId', target.id, 'failureCode', p_failure_code)
  );
  return jsonb_build_object(
    'runId', target.id,
    'status', 'failed',
    'failureCode', p_failure_code
  );
end;
$$;

revoke all on function app.begin_dynamic_import_dry_run(
  uuid, uuid, integer, uuid, text, uuid
) from public, anon;
grant execute on function app.begin_dynamic_import_dry_run(
  uuid, uuid, integer, uuid, text, uuid
) to authenticated;

revoke all on function app.get_dynamic_import_dry_run(
  uuid, app.dynamic_import_row_outcome, integer, integer
) from public, anon;
grant execute on function app.get_dynamic_import_dry_run(
  uuid, app.dynamic_import_row_outcome, integer, integer
) to authenticated;

revoke all on function app.claim_dynamic_import_run(uuid, integer)
from public, anon, authenticated;
grant execute on function app.claim_dynamic_import_run(uuid, integer)
to service_role;

revoke all on function app.stage_dynamic_import_rows(
  uuid, uuid, integer, integer, jsonb
) from public, anon, authenticated;
grant execute on function app.stage_dynamic_import_rows(
  uuid, uuid, integer, integer, jsonb
) to service_role;

revoke all on function app.analyze_dynamic_import_chunk(
  uuid, uuid, integer, integer
) from public, anon, authenticated;
grant execute on function app.analyze_dynamic_import_chunk(
  uuid, uuid, integer, integer
) to service_role;

revoke all on function app.finalize_dynamic_import_dry_run(uuid, uuid, integer)
from public, anon, authenticated;
grant execute on function app.finalize_dynamic_import_dry_run(uuid, uuid, integer)
to service_role;

revoke all on function app.fail_dynamic_import_run(uuid, uuid, integer, text)
from public, anon, authenticated;
grant execute on function app.fail_dynamic_import_run(uuid, uuid, integer, text)
to service_role;

notify pgrst, 'reload schema';
