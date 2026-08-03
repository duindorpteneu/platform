-- Correlation belongs to the durable import run so later worker transactions
-- can attach it to per-size provenance without relying on request-local state.
alter table app.dynamic_import_runs
  add column correlation_id uuid;

do $migration$
declare
  function_source text;
  needle text;
  replacement text;
begin
  function_source := pg_get_functiondef(
    'app.begin_dynamic_import_dry_run(uuid,uuid,integer,uuid,text,uuid)'::regprocedure
  );
  needle := $needle$
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
$needle$;
  replacement := $replacement$
    request_hash,
    source_row_count,
    expires_at,
    correlation_id
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
    target_batch.expires_at,
    p_correlation_id
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'DYNAMIC_IMPORT_BEGIN_PROVENANCE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'app.authorize_dynamic_import_commit(uuid,text,uuid,text,uuid)'::regprocedure
  );
  needle := $needle$
      expires_at = commit_expires_at
  where id = target.id;
$needle$;
  replacement := $replacement$
      expires_at = commit_expires_at,
      correlation_id = coalesce(target.correlation_id, p_correlation_id)
  where id = target.id;
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'DYNAMIC_IMPORT_COMMIT_PROVENANCE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

notify pgrst, 'reload schema';
