-- A blocking row remains inspectable only by its AAL2 administrator until the
-- selected-projection expiry. Ignored CSV columns and raw upload bytes are
-- never restored or exposed.

create or replace function app.get_dynamic_import_blocked_row(
  p_run_id uuid,
  p_source_row integer
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
  selected private.dynamic_import_selected_rows%rowtype;
  result app.dynamic_import_row_results%rowtype;
begin
  actor := private.require_dynamic_import_admin();
  if p_run_id is null
    or p_source_row is null
    or p_source_row not between 2 and 10001
  then
    raise exception 'DYNAMIC_IMPORT_BLOCKED_ROW_INVALID'
      using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
    and run.created_by = actor;
  select * into result
  from app.dynamic_import_row_results row_result
  where row_result.run_id = p_run_id
    and row_result.source_row = p_source_row
    and row_result.blocking;
  select * into selected
  from private.dynamic_import_selected_rows selected_row
  where selected_row.run_id = p_run_id
    and selected_row.source_row = p_source_row
    and selected_row.expires_at > timezone('utc', now());
  if target.id is null
    or result.run_id is null
    or selected.run_id is null
  then
    raise exception 'DYNAMIC_IMPORT_BLOCKED_ROW_NOT_FOUND'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'runId', target.id,
    'batchId', target.batch_id,
    'sourceRow', result.source_row,
    'reasonCodes', to_jsonb(result.reason_codes),
    'fields', selected.selected_values->'fields',
    'sizes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'articleId', entry.key::uuid,
          'articleName', article.name,
          'sourceValue', entry.value
        )
        order by article.sort_order, article.id
      )
      from jsonb_each_text(selected.selected_values->'sizes') entry
      join app.articles article on article.id = entry.key::uuid
    ), '[]'::jsonb),
    'expiresAt', selected.expires_at
  );
end;
$$;

revoke all on function app.get_dynamic_import_blocked_row(uuid, integer)
from public, anon, authenticated, service_role;
grant execute on function app.get_dynamic_import_blocked_row(uuid, integer)
to authenticated;

notify pgrst, 'reload schema';
