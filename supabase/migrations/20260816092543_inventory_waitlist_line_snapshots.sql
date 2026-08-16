create or replace function app.get_inventory_workspace_v2(
  p_season_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb;
  enriched_waitlist jsonb;
begin
  perform private.require_clothing_aal2();
  workspace := app.get_inventory_workspace(p_season_id);

  select coalesce(
    jsonb_agg(
      item.entry || jsonb_build_object(
        'article', line.product_name_snapshot,
        'size', line.size_snapshot,
        'sku', variant.sku
      )
      order by item.position
    ),
    '[]'::jsonb
  )
  into enriched_waitlist
  from jsonb_array_elements(workspace -> 'waitlist')
    with ordinality as item(entry, position)
  join app.order_lines line
    on line.id = (item.entry ->> 'orderLineId')::uuid
    and line.order_id = (item.entry ->> 'orderId')::uuid
  left join app.article_variants variant
    on variant.id = line.article_variant_id;

  return jsonb_set(workspace, '{waitlist}', enriched_waitlist, true);
end;
$$;

comment on function app.get_inventory_workspace_v2(uuid) is
  'AAL2 inventory workspace with immutable product and size snapshots on each FIFO line.';

revoke all on function app.get_inventory_workspace_v2(uuid)
from public, anon;
grant execute on function app.get_inventory_workspace_v2(uuid)
to authenticated;

notify pgrst, 'reload schema';
