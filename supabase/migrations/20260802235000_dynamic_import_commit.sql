-- Exact-once, drift-detecting commit of a completed dynamic-import dry-run.

alter table app.dynamic_import_runs
  add column commit_client_request_id uuid,
  add column commit_request_hash text check (
    commit_request_hash is null or commit_request_hash ~ '^[0-9a-f]{64}$'
  ),
  add constraint dynamic_import_runs_commit_request_shape_check check (
    (commit_client_request_id is null and commit_request_hash is null)
    or (commit_client_request_id is not null and commit_request_hash is not null)
  );

create unique index dynamic_import_runs_commit_request_idx
  on app.dynamic_import_runs(created_by, commit_client_request_id)
  where commit_client_request_id is not null;

alter table private.dynamic_import_row_plans
  add column processed_at timestamptz,
  add column committed_at timestamptz,
  add column commit_disposition text check (
    commit_disposition is null
    or commit_disposition in ('applied', 'skipped', 'blocked')
  ),
  add constraint dynamic_import_row_plans_commit_shape_check check (
    (
      processed_at is null
      and committed_at is null
      and commit_disposition is null
    )
    or (
      processed_at is not null
      and committed_at is null
      and commit_disposition in ('skipped', 'blocked')
    )
    or (
      processed_at is not null
      and committed_at is not null
      and commit_disposition = 'applied'
    )
  );

create or replace function app.authorize_dynamic_import_commit(
  p_run_id uuid,
  p_plan_hash text,
  p_client_request_id uuid,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
#variable_conflict use_variable
declare
  actor uuid;
  target app.dynamic_import_runs%rowtype;
  target_mapping app.import_mapping_revisions%rowtype;
  requested timestamptz := timezone('utc', now());
  commit_expires_at timestamptz;
  article_id uuid;
begin
  actor := private.require_dynamic_import_admin();
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_run_id is null
    or p_plan_hash is null
    or p_plan_hash !~ '^[0-9a-f]{64}$'
    or p_client_request_id is null
    or p_request_hash is null
    or p_request_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception 'DYNAMIC_IMPORT_COMMIT_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('dynamic-import-commit:' || p_run_id::text, 0)
  );
  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
    and run.created_by = actor
  for update;
  if not found then
    raise exception 'DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if target.commit_client_request_id is not null then
    if target.commit_client_request_id = p_client_request_id
      and target.commit_request_hash = p_request_hash
      and target.plan_hash = p_plan_hash
      and target.status in ('commit_queued', 'committing', 'committed')
    then
      return jsonb_build_object(
        'runId', target.id,
        'batchId', target.batch_id,
        'status', target.status::text,
        'reused', true
      );
    end if;
    raise exception 'DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
  end if;

  if target.status <> 'previewed'
    or target.plan_hash is distinct from p_plan_hash
  then
    raise exception 'DYNAMIC_IMPORT_PLAN_CHANGED' using errcode = '40001';
  end if;
  if target.expires_at <= requested
    or (
      select count(*)
      from private.dynamic_import_selected_rows selected
      where selected.run_id = target.id
        and selected.expires_at = target.expires_at
    ) <> target.source_row_count
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
    raise exception 'DYNAMIC_IMPORT_DRY_RUN_EXPIRED' using errcode = '55000';
  end if;

  select * into target_mapping
  from app.import_mapping_revisions mapping_revision
  where mapping_revision.id = target.mapping_revision_id;
  if not found
  then
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
  then
    raise exception 'DYNAMIC_IMPORT_CATALOG_CHANGED' using errcode = '40001';
  end if;

  commit_expires_at := greatest(
    target.expires_at,
    requested + interval '2 hours'
  );

  update app.dynamic_import_runs
  set status = 'commit_queued',
      commit_client_request_id = p_client_request_id,
      commit_request_hash = p_request_hash,
      commit_requested_at = requested,
      next_commit_source_row = 2,
      expires_at = commit_expires_at
  where id = target.id;
  update private.dynamic_import_selected_rows selected
  set expires_at = commit_expires_at
  where selected.run_id = target.id;
  update app.import_batches
  set expires_at = commit_expires_at
  where id = target.batch_id;

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
    'members.import.commit.queued',
    'import_batch',
    target.batch_id,
    jsonb_build_object(
      'runId', target.id,
      'rowCount', target.source_row_count,
      'outcomeCounts', target.outcome_counts
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'runId', target.id,
    'batchId', target.batch_id,
    'status', 'commit_queued',
    'reused', false
  );
end;
$$;

create or replace function private.dynamic_import_exact_variant(
  p_article_id uuid,
  p_raw_value text
)
returns uuid
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with matched as (
    select variant.id variant_id
    from app.article_variants variant
    where variant.article_id = p_article_id
      and variant.active
      and (
        private.normalize_size_match(variant.size) =
          private.normalize_size_match(p_raw_value)
        or (
          nullif(btrim(variant.sku), '') is not null
          and private.normalize_size_match(variant.sku) =
            private.normalize_size_match(p_raw_value)
        )
      )
    union
    select alias.article_variant_id
    from app.article_variant_aliases alias
    join app.article_variants variant
      on variant.id = alias.article_variant_id
      and variant.active
    where alias.article_id = p_article_id
      and alias.alias_normalized = private.normalize_size_match(p_raw_value)
  )
  select case
    when count(distinct variant_id) = 1
      then (array_agg(distinct variant_id order by variant_id))[1]
    else null
  end
  from matched;
$$;

revoke all on function private.dynamic_import_exact_variant(uuid, text)
from public, anon, authenticated, service_role;

create or replace function private.resolve_import_size_action(
  p_member_season_id uuid,
  p_season_id uuid,
  p_article_id uuid,
  p_actor uuid,
  p_batch_id uuid
)
returns integer
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  dedupe text;
  resolved_count integer;
  resolved_ids uuid[];
begin
  dedupe := encode(
    extensions.digest(
      convert_to(
        'size-conflict:' || p_member_season_id::text || ':' || p_article_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  with resolved as (
    update app.action_items item
    set status = 'resolved',
        resolved_at = timezone('utc', now()),
        resolved_by = p_actor,
        resolution_reason = 'Maatconflict door geldige herimport hersteld.'
    where item.type = 'size_conflict'
      and item.season_id = p_season_id
      and item.dedupe_key = dedupe
      and item.status in ('open', 'in_progress')
    returning item.id
  )
  select count(*)::integer, array_agg(id order by id)
  into resolved_count, resolved_ids
  from resolved;

  if resolved_count > 0 then
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    )
    select
      p_actor,
      'action_item.auto_resolved',
      'action_item',
      resolved_id,
      jsonb_build_object(
        'type', 'size_conflict',
        'seasonId', p_season_id,
        'sourceBatchId', p_batch_id
      )
    from unnest(resolved_ids) resolved_id;
  end if;
  return coalesce(resolved_count, 0);
end;
$$;

revoke all on function private.resolve_import_size_action(
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.apply_dynamic_import_row(
  p_run_id uuid,
  p_source_row integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
#variable_conflict use_variable
declare
  target_run app.dynamic_import_runs%rowtype;
  selected private.dynamic_import_selected_rows%rowtype;
  plan private.dynamic_import_row_plans%rowtype;
  fields jsonb;
  sizes jsonb;
  member_id uuid;
  member_season_id uuid;
  target_member app.members%rowtype;
  current_dob date;
  source_dob date;
  active_for_season boolean;
  team_name text;
  size_entry record;
  article_id uuid;
  variant_id uuid;
  current_size app.member_article_sizes%rowtype;
  stored_size app.member_article_sizes%rowtype;
  action_id uuid;
  dedupe_key text;
  size_conflicts integer := 0;
begin
  select * into target_run
  from app.dynamic_import_runs run
  where run.id = p_run_id;
  select * into selected
  from private.dynamic_import_selected_rows selected_row
  where selected_row.run_id = p_run_id
    and selected_row.source_row = p_source_row;
  select * into plan
  from private.dynamic_import_row_plans row_plan
  where row_plan.run_id = p_run_id
    and row_plan.source_row = p_source_row
  for update;
  if target_run.id is null
    or selected.run_id is null
    or plan.run_id is null
    or plan.committed_at is not null
  then
    raise exception 'DYNAMIC_IMPORT_COMMIT_ROW_INVALID' using errcode = '40001';
  end if;

  fields := selected.selected_values->'fields';
  sizes := selected.selected_values->'sizes';
  member_id := plan.matched_member_id;
  active_for_season := coalesce(
    (fields->>'active_for_season')::boolean,
    true
  );
  team_name := nullif(fields->>'team', '');
  source_dob := nullif(fields->>'date_of_birth', '')::date;

  if member_id is null then
    member_id := gen_random_uuid();
    insert into app.members(
      id,
      relation_number,
      first_name,
      insertion,
      last_name,
      email,
      team,
      active_for_season,
      imported_from_batch_id,
      gender
    )
    values(
      member_id,
      nullif(fields->>'external_member_id', ''),
      fields->>'first_name',
      nullif(fields->>'insertion', ''),
      fields->>'last_name',
      nullif(fields->>'email', ''),
      team_name,
      active_for_season,
      target_run.batch_id,
      coalesce(
        nullif(fields->>'gender', '')::app.gender_code,
        'unknown'::app.gender_code
      )
    );
  else
    select * into target_member
    from app.members member
    where member.id = member_id
    for update;
    if not found then
      raise exception 'DYNAMIC_IMPORT_MEMBER_DRIFT' using errcode = '40001';
    end if;

    update app.members member
    set first_name = case
          when fields ? 'first_name' then fields->>'first_name'
          else member.first_name
        end,
        insertion = case
          when fields ? 'insertion' then nullif(fields->>'insertion', '')
          else member.insertion
        end,
        last_name = case
          when fields ? 'last_name' then fields->>'last_name'
          else member.last_name
        end,
        email = case
          when fields ? 'email' then nullif(fields->>'email', '')
          else member.email
        end,
        team = coalesce(team_name, member.team),
        active_for_season = case
          when fields ? 'active_for_season' then active_for_season
          else member.active_for_season
        end,
        gender = case
          when fields ? 'gender'
            then (fields->>'gender')::app.gender_code
          else member.gender
        end,
        imported_from_batch_id = target_run.batch_id
    where member.id = member_id;
  end if;

  select sensitive.date_of_birth into current_dob
  from private.member_sensitive_identity sensitive
  where sensitive.member_id = member_id
  for update;
  if source_dob is not null
    and current_dob is not null
    and source_dob <> current_dob
  then
    raise exception 'DYNAMIC_IMPORT_DOB_DRIFT' using errcode = '40001';
  end if;
  if source_dob is not null and current_dob is null then
    update private.member_sensitive_identity sensitive
    set date_of_birth = source_dob,
        source_import_batch_id = target_run.batch_id,
        updated_by = target_run.created_by
    where sensitive.member_id = member_id;
  end if;

  member_season_id := private.ensure_member_season(member_id, target_run.season_id);
  update app.member_seasons member_season
  set team_name = coalesce(team_name, member_season.team_name),
      participation_status = case
        when fields ? 'active_for_season' or plan.matched_member_id is null
          then case
            when active_for_season then 'active'::app.member_season_status
            else 'inactive'::app.member_season_status
          end
        else member_season.participation_status
      end,
      reconciliation_status = case
        when coalesce(team_name, member_season.team_name) is not null
          and (
            fields ? 'active_for_season'
            or plan.matched_member_id is null
            or member_season.participation_status <> 'unknown'
          )
          then 'resolved'::app.member_season_reconciliation
        else member_season.reconciliation_status
      end,
      source_import_batch_id = target_run.batch_id
  where member_season.id = member_season_id;

  for size_entry in select key, value from jsonb_each_text(sizes)
  loop
    article_id := size_entry.key::uuid;
    variant_id := nullif(
      plan.resolved_variants->>article_id::text,
      ''
    )::uuid;
    if private.dynamic_import_exact_variant(
      article_id,
      size_entry.value
    ) is distinct from variant_id then
      raise exception 'DYNAMIC_IMPORT_CATALOG_DRIFT' using errcode = '40001';
    end if;
    select * into current_size
    from app.member_article_sizes size
    where size.member_id = member_id
      and size.season_id = target_run.season_id
      and size.article_id = article_id
    for update;

    if current_size.member_id is not null
      and (
        current_size.selection_status in ('confirmed', 'change_requested', 'locked')
        or (
          current_size.selection_status = 'conflict'
          and current_size.selection_source <> 'import'
        )
      )
    then
      continue;
    end if;

    if variant_id is null then
      stored_size := null;
      insert into app.member_article_sizes(
        member_id,
        season_id,
        member_season_id,
        article_id,
        article_variant_id,
        selection_status,
        selection_source,
        raw_value,
        member_note,
        confirmed_at,
        confirmed_by,
        created_by,
        updated_by
      )
      values(
        member_id,
        target_run.season_id,
        member_season_id,
        article_id,
        null,
        'conflict',
        'import',
        size_entry.value,
        null,
        null,
        null,
        target_run.created_by,
        target_run.created_by
      )
      on conflict on constraint member_article_sizes_pkey do update
      set member_season_id = excluded.member_season_id,
          article_variant_id = null,
          selection_status = 'conflict',
          selection_source = 'import',
          raw_value = excluded.raw_value,
          member_note = null,
          confirmed_at = null,
          confirmed_by = null,
          updated_by = excluded.updated_by,
          updated_at = timezone('utc', now())
      where app.member_article_sizes.selection_status = 'imported_unconfirmed'
        or (
          app.member_article_sizes.selection_status = 'conflict'
          and app.member_article_sizes.selection_source = 'import'
        )
      returning * into stored_size;
      if not found then
        select * into stored_size
        from app.member_article_sizes size
        where size.member_id = member_id
          and size.season_id = target_run.season_id
          and size.article_id = article_id;
      end if;
      if stored_size.member_id is null
        or stored_size.selection_status <> 'conflict'
        or stored_size.selection_source <> 'import'
        or stored_size.article_variant_id is not null
        or stored_size.raw_value is distinct from size_entry.value
      then
        raise exception 'DYNAMIC_IMPORT_SIZE_STATE_DRIFT'
          using errcode = '40001';
      end if;
      size_conflicts := size_conflicts + 1;

      dedupe_key := encode(
        extensions.digest(
          convert_to(
            'size-conflict:' || member_season_id::text || ':' || article_id::text,
            'UTF8'
          ),
          'sha256'
        ),
        'hex'
      );
      action_id := private.open_action_item(
        'size_conflict',
        target_run.season_id,
        'member_season',
        member_season_id,
        'import_batch',
        target_run.batch_id,
        dedupe_key,
        'warning',
        'operations',
        'unknown_import_size',
        jsonb_build_object(
          'articleId', article_id,
          'batchId', target_run.batch_id,
          'sourceRow', p_source_row
        ),
        null
      );
    else
      stored_size := null;
      insert into app.member_article_sizes(
        member_id,
        season_id,
        member_season_id,
        article_id,
        article_variant_id,
        selection_status,
        selection_source,
        raw_value,
        member_note,
        confirmed_at,
        confirmed_by,
        created_by,
        updated_by
      )
      values(
        member_id,
        target_run.season_id,
        member_season_id,
        article_id,
        variant_id,
        'imported_unconfirmed',
        'import',
        null,
        null,
        null,
        null,
        target_run.created_by,
        target_run.created_by
      )
      on conflict on constraint member_article_sizes_pkey do update
      set member_season_id = excluded.member_season_id,
          article_variant_id = excluded.article_variant_id,
          selection_status = 'imported_unconfirmed',
          selection_source = 'import',
          raw_value = null,
          member_note = null,
          confirmed_at = null,
          confirmed_by = null,
          updated_by = excluded.updated_by,
          updated_at = timezone('utc', now())
      where app.member_article_sizes.selection_status = 'imported_unconfirmed'
        or (
          app.member_article_sizes.selection_status = 'conflict'
          and app.member_article_sizes.selection_source = 'import'
        )
      returning * into stored_size;
      if not found then
        select * into stored_size
        from app.member_article_sizes size
        where size.member_id = member_id
          and size.season_id = target_run.season_id
          and size.article_id = article_id;
      end if;
      if stored_size.member_id is null
        or stored_size.article_variant_id is distinct from variant_id
        or stored_size.selection_status <> 'imported_unconfirmed'
        or stored_size.selection_source <> 'import'
      then
        raise exception 'DYNAMIC_IMPORT_SIZE_STATE_DRIFT'
          using errcode = '40001';
      end if;

      perform private.resolve_import_size_action(
        member_season_id,
        target_run.season_id,
        article_id,
        target_run.created_by,
        target_run.batch_id
      );
    end if;
  end loop;

  return jsonb_build_object(
    'memberId', member_id,
    'memberSeasonId', member_season_id,
    'sizeConflictCount', size_conflicts
  );
end;
$$;

revoke all on function private.apply_dynamic_import_row(uuid, integer)
from public, anon, authenticated, service_role;

create or replace function app.commit_dynamic_import_chunk(
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
#variable_conflict use_variable
declare
  target app.dynamic_import_runs%rowtype;
  lease private.dynamic_import_run_leases%rowtype;
  source_row integer;
  end_source_row integer;
  plan private.dynamic_import_row_plans%rowtype;
  selected private.dynamic_import_selected_rows%rowtype;
  row_result app.dynamic_import_row_results%rowtype;
  target_mapping app.import_mapping_revisions%rowtype;
  current_analysis jsonb;
  apply_result jsonb;
  identity_lock_hash text;
  member_lock_id uuid;
  article_id uuid;
  row_entity_id uuid;
  row_entity_type text;
  row_disposition text;
  processed integer := 0;
  next_row integer;
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
    raise exception 'DYNAMIC_IMPORT_COMMIT_CHUNK_INVALID' using errcode = '22023';
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
    or target.status <> 'committing'
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= timezone('utc', now())
    or target.expires_at <= timezone('utc', now())
  then
    raise exception 'DYNAMIC_IMPORT_COMMIT_LEASE_CONFLICT' using errcode = '40001';
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
    raise exception 'DYNAMIC_IMPORT_STATE_DRIFT' using errcode = '40001';
  end if;

  source_row := target.next_commit_source_row;
  end_source_row := least(
    target.source_row_count + 1,
    source_row + p_limit - 1
  );

  -- Acquire the complete chunk lockset in one global order before any row is
  -- analyzed or changed. Per-row acquisition can deadlock when two imports
  -- contain the same identities in reverse CSV order.
  for identity_lock_hash in
    select distinct identity_key.identity_key_hash
    from private.dynamic_import_selected_identity_keys identity_key
    join app.dynamic_import_row_results result
      on result.run_id = identity_key.run_id
      and result.source_row = identity_key.source_row
    join private.dynamic_import_row_plans row_plan
      on row_plan.run_id = identity_key.run_id
      and row_plan.source_row = identity_key.source_row
    where identity_key.run_id = target.id
      and identity_key.source_row between source_row and end_source_row
      and not result.blocking
      and row_plan.processed_at is null
    order by identity_key.identity_key_hash
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'dynamic-import-identity:' || identity_lock_hash,
        0
      )
    );
  end loop;

  for member_lock_id in
    select distinct row_plan.matched_member_id
    from private.dynamic_import_row_plans row_plan
    join app.dynamic_import_row_results result
      on result.run_id = row_plan.run_id
      and result.source_row = row_plan.source_row
    where row_plan.run_id = target.id
      and row_plan.source_row between source_row and end_source_row
      and row_plan.matched_member_id is not null
      and row_plan.processed_at is null
      and not result.blocking
    order by row_plan.matched_member_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'dynamic-import-member:' || member_lock_id::text,
        0
      )
    );
  end loop;

  perform 1
  from app.members member
  join (
    select distinct row_plan.matched_member_id
    from private.dynamic_import_row_plans row_plan
    join app.dynamic_import_row_results result
      on result.run_id = row_plan.run_id
      and result.source_row = row_plan.source_row
    where row_plan.run_id = target.id
      and row_plan.source_row between source_row and end_source_row
      and row_plan.matched_member_id is not null
      and row_plan.processed_at is null
      and not result.blocking
  ) lockset on lockset.matched_member_id = member.id
  order by member.id
  for update of member;

  perform 1
  from private.member_sensitive_identity sensitive
  join (
    select distinct row_plan.matched_member_id
    from private.dynamic_import_row_plans row_plan
    join app.dynamic_import_row_results result
      on result.run_id = row_plan.run_id
      and result.source_row = row_plan.source_row
    where row_plan.run_id = target.id
      and row_plan.source_row between source_row and end_source_row
      and row_plan.matched_member_id is not null
      and row_plan.processed_at is null
      and not result.blocking
  ) lockset on lockset.matched_member_id = sensitive.member_id
  order by sensitive.member_id
  for update of sensitive;

  perform 1
  from app.member_seasons member_season
  join (
    select distinct row_plan.matched_member_id
    from private.dynamic_import_row_plans row_plan
    join app.dynamic_import_row_results result
      on result.run_id = row_plan.run_id
      and result.source_row = row_plan.source_row
    where row_plan.run_id = target.id
      and row_plan.source_row between source_row and end_source_row
      and row_plan.matched_member_id is not null
      and row_plan.processed_at is null
      and not result.blocking
  ) lockset on lockset.matched_member_id = member_season.member_id
  where member_season.season_id = target.season_id
  order by member_season.member_id
  for update of member_season;

  perform 1
  from app.member_article_sizes size
  join private.dynamic_import_row_plans row_plan
    on row_plan.matched_member_id = size.member_id
    and row_plan.run_id = target.id
  join app.dynamic_import_row_results result
    on result.run_id = row_plan.run_id
    and result.source_row = row_plan.source_row
  join private.dynamic_import_selected_rows selected_row
    on selected_row.run_id = row_plan.run_id
    and selected_row.source_row = row_plan.source_row
  join lateral jsonb_object_keys(selected_row.selected_values->'sizes')
    mapped_size(article_id) on mapped_size.article_id::uuid = size.article_id
  where row_plan.source_row between source_row and end_source_row
    and row_plan.matched_member_id is not null
    and row_plan.processed_at is null
    and not result.blocking
    and size.season_id = target.season_id
  order by size.member_id, size.article_id
  for update of size;

  while source_row <= end_source_row
  loop
    select * into selected
    from private.dynamic_import_selected_rows selected_row
    where selected_row.run_id = target.id
      and selected_row.source_row = source_row;
    select * into plan
    from private.dynamic_import_row_plans row_plan
    where row_plan.run_id = target.id
      and row_plan.source_row = source_row
    for update;
    select * into row_result
    from app.dynamic_import_row_results result
    where result.run_id = target.id
      and result.source_row = source_row;
    if selected.run_id is null
      or plan.run_id is null
      or row_result.run_id is null
      or plan.processed_at is not null
    then
      raise exception 'DYNAMIC_IMPORT_COMMIT_ROW_CONFLICT' using errcode = '40001';
    end if;

    apply_result := null;
    row_entity_id := coalesce(plan.matched_member_id, target.batch_id);
    row_entity_type := case
      when plan.matched_member_id is null then 'import_batch'
      else 'member'
    end;

    if row_result.blocking then
      update private.dynamic_import_row_plans row_plan
      set processed_at = timezone('utc', now()),
          commit_disposition = 'blocked'
      where row_plan.run_id = target.id
        and row_plan.source_row = source_row;
      row_disposition := 'blocked';
    else
      if plan.matched_member_id is not null then
        -- The complete member and size lockset was acquired above. Keep this
        -- branch as an explicit guard against a plan unexpectedly losing its
        -- matched member between lockset construction and analysis.
        if not exists(
          select 1 from app.members member
          where member.id = plan.matched_member_id
        ) then
          raise exception 'DYNAMIC_IMPORT_MEMBER_DRIFT' using errcode = '40001';
        end if;
      end if;

      current_analysis := private.dynamic_import_analyze_row(
        target.id,
        source_row
      );
      if current_analysis->>'analysisHash' <> plan.analysis_hash
        or (current_analysis->>'blocking')::boolean
      then
        raise exception 'DYNAMIC_IMPORT_STATE_DRIFT' using errcode = '40001';
      end if;

      if row_result.outcome = 'skip' then
        update private.dynamic_import_row_plans row_plan
        set processed_at = timezone('utc', now()),
            commit_disposition = 'skipped'
        where row_plan.run_id = target.id
          and row_plan.source_row = source_row;
        row_disposition := 'skipped';
      else
        apply_result := private.apply_dynamic_import_row(target.id, source_row);
        row_entity_id := (apply_result->>'memberId')::uuid;
        row_entity_type := 'member';
        update private.dynamic_import_row_plans row_plan
        set processed_at = timezone('utc', now()),
            committed_at = timezone('utc', now()),
            commit_disposition = 'applied'
        where row_plan.run_id = target.id
          and row_plan.source_row = source_row;
        row_disposition := 'applied';
      end if;
    end if;

    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    )
    values(
      target.created_by,
      'members.import.row.processed',
      row_entity_type,
      row_entity_id,
      jsonb_build_object(
        'runId', target.id,
        'batchId', target.batch_id,
        'sourceRow', source_row,
        'rowOutcome', row_result.outcome,
        'commitDisposition', row_disposition,
        'selectedFieldNames', coalesce(
          (
            select jsonb_agg(field_name order by field_name)
            from jsonb_object_keys(selected.selected_values->'fields')
              selected_field(field_name)
          ),
          '[]'::jsonb
        ),
        'articleIds', coalesce(
          (
            select jsonb_agg(mapped_article_id order by mapped_article_id)
            from jsonb_object_keys(selected.selected_values->'sizes')
              mapped_article(mapped_article_id)
          ),
          '[]'::jsonb
        ),
        'changeCount', row_result.change_count,
        'conflictCount', row_result.conflict_count,
        'protectedCount', row_result.protected_count
      )
    );

    processed := processed + 1;
    source_row := source_row + 1;
  end loop;

  next_row := target.next_commit_source_row + processed;
  update app.dynamic_import_runs
  set next_commit_source_row = next_row,
      expires_at = greatest(
        expires_at,
        timezone('utc', now()) + interval '2 hours'
      )
  where id = target.id;
  update private.dynamic_import_selected_rows selected_row
  set expires_at = greatest(
    selected_row.expires_at,
    timezone('utc', now()) + interval '2 hours'
  )
  where selected_row.run_id = target.id;
  update app.import_batches
  set expires_at = greatest(
    expires_at,
    timezone('utc', now()) + interval '2 hours'
  )
  where id = target.batch_id;
  update private.dynamic_import_run_leases
  set expires_at = timezone('utc', now()) + interval '55 seconds'
  where run_id = target.id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    target.created_by,
    'members.import.commit.chunk',
    'import_batch',
    target.batch_id,
    jsonb_build_object(
      'runId', target.id,
      'startSourceRow', target.next_commit_source_row,
      'processedCount', processed,
      'nextSourceRow', next_row
    )
  );

  return jsonb_build_object(
    'runId', target.id,
    'processed', processed,
    'nextSourceRow', next_row,
    'complete', next_row = target.source_row_count + 2
  );
end;
$$;

create or replace function app.finalize_dynamic_import_commit(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer
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
  article_id uuid;
  finished timestamptz := timezone('utc', now());
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
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
    or target.status <> 'committing'
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= finished
    or target.next_commit_source_row <> target.source_row_count + 2
    or exists(
      select 1
      from private.dynamic_import_row_plans plan
      where plan.run_id = target.id
        and plan.processed_at is null
    )
  then
    raise exception 'DYNAMIC_IMPORT_COMMIT_FINALIZE_CONFLICT' using errcode = '40001';
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
    raise exception 'DYNAMIC_IMPORT_STATE_DRIFT' using errcode = '40001';
  end if;

  update app.dynamic_import_runs
  set status = 'committed',
      committed_at = finished
  where id = target.id;
  update app.import_batches
  set dynamic_status = 'committed',
      status = 'committed',
      committed_at = finished,
      failure_code = null
  where id = target.batch_id;
  delete from private.dynamic_import_selected_rows selected
  where selected.run_id = target.id
    and not exists(
      select 1
      from app.dynamic_import_row_results result
      where result.run_id = selected.run_id
        and result.source_row = selected.source_row
        and result.blocking
    );
  delete from private.dynamic_import_row_plans
  where run_id = target.id;
  delete from private.dynamic_import_run_leases
  where run_id = target.id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    target.created_by,
    'members.import.commit.completed',
    'import_batch',
    target.batch_id,
    jsonb_build_object(
      'runId', target.id,
      'rowCount', target.source_row_count,
      'outcomeCounts', target.outcome_counts
    )
  );

  return jsonb_build_object(
    'runId', target.id,
    'batchId', target.batch_id,
    'status', 'committed',
    'committedAt', finished,
    'outcomeCounts', target.outcome_counts
  );
end;
$$;

revoke all on function app.authorize_dynamic_import_commit(
  uuid, text, uuid, text, uuid
) from public, anon;
grant execute on function app.authorize_dynamic_import_commit(
  uuid, text, uuid, text, uuid
) to authenticated;

revoke all on function app.commit_dynamic_import_chunk(
  uuid, uuid, integer, integer
) from public, anon, authenticated;
grant execute on function app.commit_dynamic_import_chunk(
  uuid, uuid, integer, integer
) to service_role;

revoke all on function app.finalize_dynamic_import_commit(uuid, uuid, integer)
from public, anon, authenticated;
grant execute on function app.finalize_dynamic_import_commit(uuid, uuid, integer)
to service_role;

notify pgrst, 'reload schema';
