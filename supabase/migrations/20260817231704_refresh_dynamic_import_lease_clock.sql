-- Dynamic-import chunks renew their lease near the end of each transaction.
-- The original functions use now(), which is fixed at transaction start. A
-- chunk that runs for most of the 55-second lease can therefore publish an
-- already stale expiry and be reclaimed while its worker is still active.
-- Normalize same-owner renewals against the actual wall clock at statement
-- execution time. Reclaims change token/generation and remain untouched.

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
  claimed timestamptz;
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

  perform pg_advisory_xact_lock(
    hashtextextended('dynamic-import-run-claim', 0)
  );
  claimed := clock_timestamp();

  select run.* into target
  from app.dynamic_import_runs run
  left join private.dynamic_import_run_leases lease
    on lease.run_id = run.id
  where (
      run.status = 'queued_preview'
      or (
        run.status = 'staging'
        and (lease.run_id is null or lease.expires_at <= claimed)
      )
      or run.status = 'commit_queued'
      or (
        run.status = 'committing'
        and (lease.run_id is null or lease.expires_at <= claimed)
      )
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

  -- READ COMMITTED can select an expired joined lease and then lock a run
  -- whose worker renewed immediately before this lock was acquired. Re-read
  -- after the run lock; chunks always lock the run before their lease.
  if target.status in ('staging', 'committing')
    and exists(
      select 1
      from private.dynamic_import_run_leases current_lease
      where current_lease.run_id = target.id
        and current_lease.expires_at > clock_timestamp()
    )
  then
    return jsonb_build_object('job', null);
  end if;

  select * into target_mapping
  from app.import_mapping_revisions mapping_revision
  where mapping_revision.id = target.mapping_revision_id;
  if not found then
    raise exception 'DYNAMIC_IMPORT_MAPPING_NOT_FOUND'
      using errcode = 'P0002';
  end if;

  claimed := clock_timestamp();
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
  returning private.dynamic_import_run_leases.generation
  into generation;

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
      'phase',
        case
          when target.status = 'committing' then 'commit'
          else 'preview'
        end,
      'generation', generation,
      'nextSourceRow',
        case
          when target.status = 'committing'
            then target.next_commit_source_row
          else target.next_source_row
        end,
      'nextAnalysisSourceRow', target.next_analysis_source_row,
      'sourceRowCount', target.source_row_count,
      'expiresAt', target.expires_at
    )
  );
end;
$$;

revoke all on function app.claim_dynamic_import_run(uuid, integer)
from public, anon, authenticated;
grant execute on function app.claim_dynamic_import_run(uuid, integer)
to service_role;

create function private.refresh_dynamic_import_lease_expiry_clock()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  if new.claim_token = old.claim_token
    and new.generation = old.generation
    and new.claimed_at = old.claimed_at
    and new.expires_at is distinct from old.expires_at
  then
    new.expires_at := greatest(
      new.expires_at,
      clock_timestamp() + interval '55 seconds'
    );
  end if;
  return new;
end;
$$;

revoke all on function private.refresh_dynamic_import_lease_expiry_clock()
from public, anon, authenticated, service_role;

create trigger dynamic_import_lease_expiry_clock
before update of expires_at on private.dynamic_import_run_leases
for each row execute function private.refresh_dynamic_import_lease_expiry_clock();

comment on function private.refresh_dynamic_import_lease_expiry_clock() is
  'Keeps same-owner dynamic-import lease renewals 55 seconds ahead of wall-clock completion time.';

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260817231704_refresh_dynamic_import_lease_clock',
  'passed',
  jsonb_build_object(
    'strategy', 'wall-clock floor on same-owner lease renewal',
    'lease_seconds', 55,
    'dynamic_import_enabled', (
      select enabled
      from app.release_feature_flags
      where key = 'dynamic_import_v2'
    )
  )
);
