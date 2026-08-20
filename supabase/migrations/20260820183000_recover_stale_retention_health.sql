-- An interrupted retention run is historical once a later run of the same
-- operation completed successfully. Keep every run ledger row, but derive the
-- current running-stale flag from unrecovered runs only.

alter function app.get_operational_health_v13(
  text,
  integer,
  text,
  integer
) rename to get_operational_health_v13_before_retention_recovery;

revoke all on function app.get_operational_health_v13_before_retention_recovery(
  text,
  integer,
  text,
  integer
) from public, anon, authenticated, service_role;

create function app.get_operational_health_v13(
  p_current_pepper_fingerprint text,
  p_current_key_version integer,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot jsonb := app.get_operational_health_v13_before_retention_recovery(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
  unrecovered_stale_retention_run boolean;
begin
  select exists (
    select 1
    from private.operation_runs stale_run
    where stale_run.operation = 'retention'
      and stale_run.status = 'running'
      and stale_run.started_at
        < statement_timestamp() - interval '15 minutes'
      and not exists (
        select 1
        from private.operation_runs recovery_run
        where recovery_run.operation = stale_run.operation
          and recovery_run.status = 'succeeded'
          and recovery_run.started_at > stale_run.started_at
          and recovery_run.finished_at > stale_run.started_at
      )
  ) into unrecovered_stale_retention_run;

  return jsonb_set(
    snapshot,
    '{operations,retention,runningStale}',
    to_jsonb(unrecovered_stale_retention_run),
    false
  );
end;
$$;

revoke all on function app.get_operational_health_v13(
  text,
  integer,
  text,
  integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v13(
  text,
  integer,
  text,
  integer
) to service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260820183000_recover_stale_retention_health',
  'passed',
  jsonb_build_object(
    'strategy',
      'derive retention running-stale only from runs without later success',
    'recoveredStaleRuns',
      (
        select count(*)
        from private.operation_runs stale_run
        where stale_run.operation = 'retention'
          and stale_run.status = 'running'
          and stale_run.started_at
            < statement_timestamp() - interval '15 minutes'
          and exists (
            select 1
            from private.operation_runs recovery_run
            where recovery_run.operation = stale_run.operation
              and recovery_run.status = 'succeeded'
              and recovery_run.started_at > stale_run.started_at
              and recovery_run.finished_at > stale_run.started_at
          )
      )
  )
);

notify pgrst, 'reload schema';
