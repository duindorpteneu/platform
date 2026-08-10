-- Safe resume metadata for administrator-owned dynamic-import runs.

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
        'committedAt', batch.committed_at,
        'runId', latest_run.id,
        'runStatus', latest_run.status::text
      ) order by batch.created_at desc)
      from (
        select import_batch.*
        from app.import_batches import_batch
        where import_batch.schema_version = 2
          and import_batch.actor_user_id = actor
        order by import_batch.created_at desc
        limit 10
      ) batch
      left join lateral (
        select run.id, run.status
        from app.dynamic_import_runs run
        where run.batch_id = batch.id
          and run.created_by = actor
        order by run.created_at desc, run.id
        limit 1
      ) latest_run on true
    ), '[]'::jsonb)
  );
end;
$$;

notify pgrst, 'reload schema';
