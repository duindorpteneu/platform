-- Flexible dynamic imports and explicit manual member creation.
--
-- Optional import values may be discarded by an administrator per mapping
-- revision. Identity conflicts and protected size choices remain blocking.
-- Manual creation is administrator + AAL2 only and never creates access,
-- communication, package orders, payments or size selections.

alter table app.members
  alter column team drop not null;

alter table app.members
  add constraint members_optional_team_check check (
    team is null
    or (
      team = btrim(team)
      and length(team) between 1 and 120
      and team !~ '[[:cntrl:]]'
    )
  ) not valid;

alter table app.members validate constraint members_optional_team_check;

create table private.dynamic_import_mapping_preferences (
  mapping_revision_id uuid primary key
    references app.import_mapping_revisions(id) on delete cascade,
  ignore_optional_conflicts boolean not null default false,
  created_by uuid not null,
  created_at timestamptz not null default timezone('utc', now())
);

alter table private.dynamic_import_mapping_preferences enable row level security;
revoke all on table private.dynamic_import_mapping_preferences
from public, anon, authenticated, service_role;

create or replace function app.save_dynamic_import_mapping_v2(
  p_batch_id uuid,
  p_expected_revision integer,
  p_expected_catalog_hash text,
  p_header_hash text,
  p_mapping jsonb,
  p_policy jsonb,
  p_ignore_optional_conflicts boolean,
  p_preset_id uuid default null,
  p_preset_revision integer default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
#variable_conflict use_variable
declare
  actor uuid := private.require_admin_aal2();
  result jsonb;
  revision_id uuid;
  existing_preference boolean;
  preference_exists boolean := false;
begin
  if p_ignore_optional_conflicts is null then
    raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
  end if;

  result := app.save_dynamic_import_mapping(
    p_batch_id,
    p_expected_revision,
    p_expected_catalog_hash,
    p_header_hash,
    p_mapping,
    p_policy,
    p_preset_id,
    p_preset_revision,
    p_correlation_id
  );

  select batch.active_mapping_revision_id into revision_id
  from app.import_batches batch
  where batch.id = p_batch_id
    and batch.actor_user_id = actor;
  if revision_id is null then
    raise exception 'DYNAMIC_IMPORT_MAPPING_NOT_FOUND' using errcode = 'P0002';
  end if;

  select preference.ignore_optional_conflicts into existing_preference
  from private.dynamic_import_mapping_preferences preference
  where preference.mapping_revision_id = revision_id;
  preference_exists := found;
  if found and existing_preference is distinct from p_ignore_optional_conflicts then
    raise exception 'DYNAMIC_IMPORT_REVISION_CHANGED' using errcode = '40001';
  end if;

  insert into private.dynamic_import_mapping_preferences(
    mapping_revision_id,
    ignore_optional_conflicts,
    created_by
  )
  values(revision_id, p_ignore_optional_conflicts, actor)
  on conflict (mapping_revision_id) do nothing;

  if not preference_exists then
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
      'members.import.optional_policy.saved',
      'import_batch',
      p_batch_id,
      jsonb_build_object(
        'mappingRevisionId', revision_id,
        'ignoreOptionalConflicts', p_ignore_optional_conflicts
      ),
      p_correlation_id
    );
  end if;

  return result;
end;
$$;

revoke all on function app.save_dynamic_import_mapping_v2(
  uuid, integer, text, text, jsonb, jsonb, boolean, uuid, integer, uuid
) from public, anon;
grant execute on function app.save_dynamic_import_mapping_v2(
  uuid, integer, text, text, jsonb, jsonb, boolean, uuid, integer, uuid
) to authenticated;

create or replace function app.filter_dynamic_import_optional_conflicts(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target app.dynamic_import_runs%rowtype;
  lease private.dynamic_import_run_leases%rowtype;
  ignore_optional boolean := false;
  filtered jsonb;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if p_run_id is null
    or p_claim_token is null
    or p_generation is null
    or p_generation < 1
    or jsonb_typeof(p_rows) <> 'array'
    or jsonb_array_length(p_rows) not between 1 and 250
  then
    raise exception 'DYNAMIC_IMPORT_CHUNK_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id;
  select * into lease
  from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = p_run_id;
  if target.id is null
    or lease.run_id is null
    or target.status <> 'staging'
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= timezone('utc', now())
    or target.expires_at <= timezone('utc', now())
  then
    raise exception 'DYNAMIC_IMPORT_LEASE_CONFLICT' using errcode = '40001';
  end if;

  select preference.ignore_optional_conflicts into ignore_optional
  from private.dynamic_import_mapping_preferences preference
  where preference.mapping_revision_id = target.mapping_revision_id;
  ignore_optional := coalesce(ignore_optional, false);
  if not ignore_optional then
    return p_rows;
  end if;

  select jsonb_agg(
    jsonb_set(
      jsonb_set(
        row_value,
        '{errors}',
        coalesce((
          select jsonb_agg(error_value order by error_value #>> '{}')
          from jsonb_array_elements(row_value->'errors') error_value
          where error_value #>> '{}' not in (
            'invalid_insertion',
            'invalid_team',
            'invalid_gender',
            'invalid_active_for_season'
          )
            and error_value #>> '{}' not like 'invalid_size_%'
        ), '[]'::jsonb)
      ),
      '{sizes}',
      coalesce((
        select jsonb_object_agg(size_entry.key, size_entry.value)
        from jsonb_each_text(row_value->'sizes') size_entry
        where private.dynamic_import_exact_variant(
          size_entry.key::uuid,
          size_entry.value
        ) is not null
      ), '{}'::jsonb)
    )
    order by (row_value->>'sourceRow')::integer
  ) into filtered
  from jsonb_array_elements(p_rows) row_value;

  return filtered;
end;
$$;

revoke all on function app.filter_dynamic_import_optional_conflicts(
  uuid, uuid, integer, jsonb
) from public, anon, authenticated;
grant execute on function app.filter_dynamic_import_optional_conflicts(
  uuid, uuid, integer, jsonb
) to service_role;

alter function private.dynamic_import_analyze_row(uuid, integer)
rename to dynamic_import_analyze_row_v1;

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
declare
  base jsonb;
  ignore_optional boolean := false;
  reasons text[];
  blocking boolean;
  conflict_count integer;
  outcome app.dynamic_import_row_outcome;
  analysis_hash text;
begin
  base := private.dynamic_import_analyze_row_v1(p_run_id, p_source_row);
  select preference.ignore_optional_conflicts into ignore_optional
  from app.dynamic_import_runs run
  join private.dynamic_import_mapping_preferences preference
    on preference.mapping_revision_id = run.mapping_revision_id
  where run.id = p_run_id;
  if not coalesce(ignore_optional, false) then
    return base;
  end if;

  reasons := array(
    select distinct reason
    from jsonb_array_elements_text(base->'reasonCodes') reason
    where reason not in ('missing_team', 'unknown_size')
    order by reason
  );
  blocking := exists(
    select 1
    from unnest(reasons) reason
    where reason <> 'confirmed_size_protected'
  );
  conflict_count := case
    when 'unknown_size' = any(array(
      select jsonb_array_elements_text(base->'reasonCodes')
    )) then 0
    else (base->>'conflictCount')::integer
  end;
  outcome := case
    when blocking and exists(
      select 1 from unnest(reasons) reason
      where reason like 'invalid_%'
        or reason in ('missing_first_name', 'missing_last_name')
    ) then 'error'::app.dynamic_import_row_outcome
    when blocking then 'conflict'::app.dynamic_import_row_outcome
    when conflict_count > 0 then 'conflict'::app.dynamic_import_row_outcome
    when (base->>'protectedCount')::integer > 0
      then 'protected'::app.dynamic_import_row_outcome
    when nullif(base->>'matchedMemberId', '') is null
      then 'create'::app.dynamic_import_row_outcome
    when (base->>'changeCount')::integer > 0
      then 'update'::app.dynamic_import_row_outcome
    else 'skip'::app.dynamic_import_row_outcome
  end;

  analysis_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'outcome', outcome::text,
          'blocking', blocking,
          'reasonCodes', to_jsonb(reasons),
          'matchedMemberId', nullif(base->>'matchedMemberId', '')::uuid,
          'stateHash', base->>'stateHash',
          'resolvedVariants', base->'resolvedVariants',
          'changeCount', (base->>'changeCount')::integer,
          'conflictCount', conflict_count,
          'protectedCount', (base->>'protectedCount')::integer
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
    'reasonCodes', to_jsonb(reasons),
    'matchedMemberId', nullif(base->>'matchedMemberId', '')::uuid,
    'stateHash', base->>'stateHash',
    'resolvedVariants', base->'resolvedVariants',
    'analysisHash', analysis_hash,
    'changeCount', (base->>'changeCount')::integer,
    'conflictCount', conflict_count,
    'protectedCount', (base->>'protectedCount')::integer
  );
end;
$$;

revoke all on function private.dynamic_import_analyze_row(uuid, integer)
from public, anon, authenticated, service_role;
revoke all on function private.dynamic_import_analyze_row_v1(uuid, integer)
from public, anon, authenticated, service_role;

create or replace function private.ensure_member_season(
  p_member_id uuid,
  p_season_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result uuid;
  active_season uuid;
  target_member app.members%rowtype;
  is_current boolean;
  member_found boolean;
  can_reconcile boolean;
begin
  if p_member_id is null or p_season_id is null then
    raise exception 'MEMBER_SEASON_INPUT_INVALID' using errcode = '22023';
  end if;
  select active_season_id into active_season
  from app.app_settings where id = true;
  is_current := active_season is not distinct from p_season_id;
  select * into target_member
  from app.members member where member.id = p_member_id;
  member_found := found;
  can_reconcile := member_found and is_current and target_member.team is not null;

  insert into app.member_seasons(
    member_id, season_id, team_name, participation_status,
    reconciliation_status, source_import_batch_id
  )
  values(
    p_member_id,
    p_season_id,
    case when member_found and is_current then target_member.team else null end,
    case
      when not member_found or not is_current then 'unknown'::app.member_season_status
      when target_member.active_for_season then 'active'::app.member_season_status
      else 'inactive'::app.member_season_status
    end,
    case
      when can_reconcile then 'resolved'::app.member_season_reconciliation
      else 'legacy_unknown'::app.member_season_reconciliation
    end,
    case when member_found and is_current then target_member.imported_from_batch_id else null end
  )
  on conflict (member_id, season_id) do update
  set team_name = case
        when excluded.reconciliation_status = 'resolved' then excluded.team_name
        else app.member_seasons.team_name
      end,
      participation_status = case
        when excluded.reconciliation_status = 'resolved' then excluded.participation_status
        else app.member_seasons.participation_status
      end,
      reconciliation_status = case
        when excluded.reconciliation_status = 'resolved' then excluded.reconciliation_status
        else app.member_seasons.reconciliation_status
      end,
      source_import_batch_id = coalesce(
        excluded.source_import_batch_id,
        app.member_seasons.source_import_batch_id
      ),
      updated_at = case
        when excluded.reconciliation_status = 'resolved' and (
          app.member_seasons.team_name is distinct from excluded.team_name
          or app.member_seasons.participation_status is distinct from excluded.participation_status
          or app.member_seasons.reconciliation_status is distinct from excluded.reconciliation_status
          or (
            excluded.source_import_batch_id is not null
            and app.member_seasons.source_import_batch_id is distinct from excluded.source_import_batch_id
          )
        ) then timezone('utc', now())
        else app.member_seasons.updated_at
      end
  returning id into result;
  return result;
end;
$$;

revoke all on function private.ensure_member_season(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.manual_member_candidate_snapshot(
  p_external_id text,
  p_first_name text,
  p_insertion text,
  p_last_name text,
  p_email text,
  p_date_of_birth date
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  with active_season as (
    select season.id, season.name
    from app.app_settings settings
    join app.seasons season on season.id = settings.active_season_id
    where settings.id = true and season.status = 'open'
  ), candidates as (
    select
      member.id,
      concat_ws(' ', member.first_name, member.insertion, member.last_name) member_name,
      member_season.team_name,
      array_remove(array[
        case when p_external_id is not null and exists(
          select 1 from app.member_external_identities external_identity
          where external_identity.member_id = member.id
            and external_identity.issuer = 'sportlink'
            and external_identity.external_id_normalized = upper(p_external_id)
        ) then 'external_id' end,
        case when private.dynamic_import_member_name_key(
          member.first_name, member.insertion, member.last_name
        ) = private.dynamic_import_member_name_key(
          p_first_name, p_insertion, p_last_name
        ) and p_date_of_birth is not null and sensitive.date_of_birth = p_date_of_birth
          then 'name_date_of_birth' end,
        case when private.dynamic_import_member_name_key(
          member.first_name, member.insertion, member.last_name
        ) = private.dynamic_import_member_name_key(
          p_first_name, p_insertion, p_last_name
        ) and p_email is not null and lower(member.email) = lower(p_email)
          then 'name_email' end,
        case when p_external_id is null and p_date_of_birth is null and p_email is null
          and private.dynamic_import_member_name_key(
            member.first_name, member.insertion, member.last_name
          ) = private.dynamic_import_member_name_key(
            p_first_name, p_insertion, p_last_name
          ) then 'name_only' end
      ], null) reasons
    from app.members member
    left join private.member_sensitive_identity sensitive on sensitive.member_id = member.id
    left join active_season season on true
    left join app.member_seasons member_season
      on member_season.member_id = member.id and member_season.season_id = season.id
  ), matched as (
    select * from candidates where cardinality(reasons) > 0
  ), snapshot as (
    select jsonb_build_object(
      'seasonId', season.id,
      'seasonName', season.name,
      'candidates', coalesce((
        select jsonb_agg(jsonb_build_object(
          'memberId', matched.id,
          'memberName', matched.member_name,
          'team', matched.team_name,
          'reasons', to_jsonb(matched.reasons)
        ) order by matched.member_name, matched.id)
        from matched
      ), '[]'::jsonb)
    ) value
    from active_season season
  )
  select case
    when snapshot.value is null then null
    else snapshot.value || jsonb_build_object(
      'fingerprint', encode(
        extensions.digest(convert_to(snapshot.value::text, 'UTF8'), 'sha256'),
        'hex'
      )
    )
  end
  from snapshot;
$$;

revoke all on function private.manual_member_candidate_snapshot(
  text, text, text, text, text, date
) from public, anon, authenticated, service_role;

create or replace function app.preflight_manual_member_create(
  p_external_id text,
  p_first_name text,
  p_insertion text,
  p_last_name text,
  p_email text,
  p_date_of_birth date
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
  perform private.require_admin_aal2();
  result := private.manual_member_candidate_snapshot(
    p_external_id, p_first_name, p_insertion, p_last_name, p_email, p_date_of_birth
  );
  if result is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;
  return result;
end;
$$;

create unique index audit_logs_manual_member_request_idx
on app.audit_logs(actor_user_id, (metadata->>'clientRequestId'))
where action = 'member.manual.created' and metadata ? 'clientRequestId';

create or replace function app.create_manual_member(
  p_external_id text,
  p_first_name text,
  p_insertion text,
  p_last_name text,
  p_email text,
  p_date_of_birth date,
  p_gender app.gender_code,
  p_team text,
  p_client_request_id uuid,
  p_expected_fingerprint text,
  p_allow_potential_duplicate boolean,
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
  external_id text := upper(nullif(btrim(normalize(p_external_id, NFKC)), ''));
  first_name text := nullif(btrim(regexp_replace(normalize(p_first_name, NFKC), '[[:space:]]+', ' ', 'g')), '');
  insertion text := nullif(btrim(regexp_replace(normalize(p_insertion, NFKC), '[[:space:]]+', ' ', 'g')), '');
  last_name text := nullif(btrim(regexp_replace(normalize(p_last_name, NFKC), '[[:space:]]+', ' ', 'g')), '');
  email text := lower(nullif(btrim(normalize(p_email, NFKC)), ''));
  team text := nullif(btrim(regexp_replace(normalize(p_team, NFKC), '[[:space:]]+', ' ', 'g')), '');
  snapshot jsonb;
  payload_hash text;
  previous app.audit_logs%rowtype;
  member_id uuid;
  member_season_id uuid;
  season_id uuid;
begin
  if p_client_request_id is null
    or p_expected_fingerprint !~ '^[0-9a-f]{64}$'
    or p_allow_potential_duplicate is null
    or first_name is null or length(first_name) > 120
    or last_name is null or length(last_name) > 120
    or length(coalesce(insertion, '')) > 80
    or length(coalesce(external_id, '')) > 120
    or length(coalesce(email, '')) > 320
    or length(coalesce(team, '')) > 120
    or concat_ws('', external_id, first_name, insertion, last_name, email, team) ~ '[[:cntrl:]]'
    or (p_date_of_birth is not null and p_date_of_birth not between date '1900-01-01' and current_date)
  then
    raise exception 'MANUAL_MEMBER_INPUT_INVALID' using errcode = '22023';
  end if;

  payload_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'externalId', external_id,
    'firstName', first_name,
    'insertion', insertion,
    'lastName', last_name,
    'email', email,
    'dateOfBirth', p_date_of_birth,
    'gender', p_gender::text,
    'team', team,
    'allowPotentialDuplicate', p_allow_potential_duplicate
  )::text, 'UTF8'), 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    'manual-member-request:' || p_client_request_id::text,
    0
  ));
  select * into previous
  from app.audit_logs audit
  where audit.actor_user_id = actor
    and audit.action = 'member.manual.created'
    and audit.metadata->>'clientRequestId' = p_client_request_id::text;
  if found then
    if previous.metadata->>'payloadHash' <> payload_hash then
      raise exception 'MANUAL_MEMBER_REQUEST_REUSED' using errcode = 'P0001';
    end if;
    return jsonb_build_object(
      'memberId', previous.entity_id,
      'memberSeasonId', previous.metadata->>'memberSeasonId',
      'reused', true
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'manual-member:' || private.dynamic_import_member_name_key(first_name, insertion, last_name),
    0
  ));
  snapshot := private.manual_member_candidate_snapshot(
    external_id, first_name, insertion, last_name, email, p_date_of_birth
  );
  if snapshot is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;
  if snapshot->>'fingerprint' <> p_expected_fingerprint then
    raise exception 'MANUAL_MEMBER_PREFLIGHT_CHANGED' using errcode = '40001';
  end if;
  if exists(
    select 1 from jsonb_array_elements(snapshot->'candidates') candidate,
      jsonb_array_elements_text(candidate->'reasons') reason
    where reason = 'external_id'
  ) then
    raise exception 'MANUAL_MEMBER_EXTERNAL_ID_EXISTS' using errcode = 'P0001';
  end if;
  if jsonb_array_length(snapshot->'candidates') > 0 and not p_allow_potential_duplicate then
    raise exception 'MANUAL_MEMBER_DUPLICATE_CONFIRMATION_REQUIRED' using errcode = 'P0001';
  end if;

  season_id := (snapshot->>'seasonId')::uuid;
  insert into app.members(
    relation_number, first_name, insertion, last_name, email, team,
    active_for_season, imported_from_batch_id, gender
  ) values(
    external_id, first_name, insertion, last_name, email, team,
    true, null, coalesce(p_gender, 'unknown'::app.gender_code)
  ) returning id into member_id;

  update private.member_sensitive_identity sensitive
  set date_of_birth = p_date_of_birth,
      source_import_batch_id = null,
      updated_by = actor
  where sensitive.member_id = member_id;

  member_season_id := private.ensure_member_season(member_id, season_id);
  update app.member_seasons member_season
  set team_name = team,
      participation_status = 'active',
      reconciliation_status = case
        when team is null then 'legacy_unknown'::app.member_season_reconciliation
        else 'resolved'::app.member_season_reconciliation
      end,
      source_import_batch_id = null
  where member_season.id = member_season_id;

  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  ) values(
    actor,
    'member.manual.created',
    'member',
    member_id,
    jsonb_build_object(
      'clientRequestId', p_client_request_id,
      'payloadHash', payload_hash,
      'memberSeasonId', member_season_id,
      'seasonId', season_id,
      'hasExternalId', external_id is not null,
      'hasEmail', email is not null,
      'hasDateOfBirth', p_date_of_birth is not null,
      'hasTeam', team is not null,
      'potentialDuplicateConfirmed', p_allow_potential_duplicate
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'memberId', member_id,
    'memberSeasonId', member_season_id,
    'reused', false
  );
exception when unique_violation then
  raise exception 'MANUAL_MEMBER_EXTERNAL_ID_EXISTS' using errcode = '23505';
end;
$$;

revoke all on function app.preflight_manual_member_create(
  text, text, text, text, text, date
) from public, anon;
grant execute on function app.preflight_manual_member_create(
  text, text, text, text, text, date
) to authenticated;

revoke all on function app.create_manual_member(
  text, text, text, text, text, date, app.gender_code, text,
  uuid, text, boolean, uuid
) from public, anon;
grant execute on function app.create_manual_member(
  text, text, text, text, text, date, app.gender_code, text,
  uuid, text, boolean, uuid
) to authenticated;

notify pgrst, 'reload schema';
