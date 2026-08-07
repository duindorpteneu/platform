-- Staff may dismiss a false/accepted exception with a reason, but may never
-- mark a domain exception as repaired solely by typing free text. A resolved
-- status is written by the domain mutation that can prove the condition is
-- gone through private.auto_resolve_action_item.

create or replace function app.get_action_item_workspace_v2(
  p_season_id uuid default null,
  p_status app.action_item_status default null,
  p_severity app.action_item_severity default null,
  p_owner_user_id uuid default null,
  p_only_unassigned boolean default false,
  p_offset integer default 0,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb;
  safe_items jsonb;
begin
  workspace := app.get_action_item_workspace(
    p_season_id,
    p_status,
    p_severity,
    p_owner_user_id,
    p_only_unassigned,
    p_offset,
    p_limit
  );
  select coalesce(
    jsonb_agg(
      jsonb_set(item, '{actions,canResolve}', 'false'::jsonb, false)
      order by ordinal
    ),
    '[]'::jsonb
  )
  into safe_items
  from jsonb_array_elements(workspace->'items')
    with ordinality as page(item, ordinal);
  return jsonb_set(workspace, '{items}', safe_items, false);
end;
$$;

revoke all on function app.get_action_item_workspace_v2(
  uuid, app.action_item_status, app.action_item_severity,
  uuid, boolean, integer, integer
) from public, anon, service_role;
grant execute on function app.get_action_item_workspace_v2(
  uuid, app.action_item_status, app.action_item_severity,
  uuid, boolean, integer, integer
) to authenticated;

create or replace function app.resolve_action_item_v3(
  p_action_item_id uuid,
  p_expected_revision integer,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_clothing_aal2();
  if p_action_item_id is null
    or p_expected_revision is null
    or p_expected_revision < 1
    or p_reason is null
    or length(btrim(p_reason)) not between 3 and 500
  then
    raise exception 'ACTION_ITEM_RESOLUTION_INVALID' using errcode = '22023';
  end if;
  raise exception 'ACTION_ITEM_DOMAIN_REPAIR_REQUIRED'
    using errcode = '23514';
end;
$$;

revoke execute on function app.resolve_action_item_v2(
  uuid, integer, text, uuid
) from authenticated;
revoke all on function app.resolve_action_item_v3(
  uuid, integer, text, uuid
) from public, anon, service_role;
grant execute on function app.resolve_action_item_v3(
  uuid, integer, text, uuid
) to authenticated;

notify pgrst, 'reload schema';
